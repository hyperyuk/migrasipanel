#!/bin/bash

# Fungsi error handling
error_exit() {
    echo "Error: $1" >&2
    exit 1
}

# Fungsi setup SSH (sederhana: default key-based)
setup_ssh() {
    local target_ip=$1
    local target_type=$2
    echo "=== Setup SSH untuk $target_type ke $target_ip ==="
    
    # Default values
    SSH_USER=${SSH_USER:-"root"}
    SSH_PORT=${SSH_PORT:-"22"}
    
    # Prompt minimal
    read -p "SSH User (default: $SSH_USER): " input_user
    SSH_USER=${input_user:-$SSH_USER}
    read -p "SSH Port (default: $SSH_PORT): " input_port
    SSH_PORT=${input_port:-$SSH_PORT}
    
    read -p "Pakai SSH Password? (y/n, default: n): " USE_PASS
    if [[ $USE_PASS =~ ^[Yy]$ ]]; then
        read -s -p "SSH Password: " SSH_PASS
        echo
        apt update && apt install -y sshpass >/dev/null 2>&1 || error_exit "Gagal install sshpass"
        SSH_CMD="sshpass -p '$SSH_PASS' ssh -o StrictHostKeyChecking=no -p $SSH_PORT $SSH_USER@$target_ip"
        SCP_CMD="sshpass -p '$SSH_PASS' scp -o StrictHostKeyChecking=no -P $SSH_PORT"
    else
        SSH_CMD="ssh -o StrictHostKeyChecking=no -p $SSH_PORT $SSH_USER@$target_ip"
        SCP_CMD="scp -o StrictHostKeyChecking=no -P $SSH_PORT"
    fi

    # Test SSH
    echo "Testing SSH..."
    $SSH_CMD "echo 'SSH OK'" || error_exit "Gagal connect SSH ke $target_ip. Cek user/pass/key/port/firewall."
    echo "SSH OK!"
}

# Fungsi Migrasi Panel (input minimal)
migrate_panel() {
    echo "=== MIGRASE PANEL ==="
    
    # Args atau prompt untuk esensial
    if [ -z "$OLD_IP" ]; then read -p "IP/Hostname VPS Lama: " OLD_IP; fi
    setup_ssh "$OLD_IP" "panel"
    
    # Default paths & DB
    OLD_PANEL_PATH=${OLD_PANEL_PATH:-"/var/www/pterodactyl"}
    OLD_DB_HOST=${OLD_DB_HOST:-"localhost"}
    OLD_DB_NAME=${OLD_DB_NAME:-"panel"}
    PANEL_PATH=${PANEL_PATH:-"/var/www/pterodactyl"}
    DB_USER=${DB_USER:-"pterodactyl"}
    DB_NAME=${DB_NAME:-"panel"}
    WINGS_SSL_PORT=${WINGS_SSL_PORT:-"2022"}  # Default, tapi bisa override
    
    # Prompt esensial saja
    read -p "DB Username Lama: " OLD_DB_USER
    read -s -p "DB Password Lama: " OLD_DB_PASS
    echo
    read -s -p "MySQL Root Password Baru: " ROOT_PASS
    echo
    read -s -p "DB Password Baru: " DB_PASS
    echo
    if [ -z "$NEW_DOMAIN" ]; then read -p "Domain/IP Baru: " NEW_DOMAIN; fi

    DATE=$(date +%Y%m%d_%H%M%S)
    BACKUP_DIR="/tmp/pterodactyl_backup"
    OLD_BACKUP_DIR="/tmp/pterodactyl_backup"

    echo "Mulai migrasi panel pada $(date)..."

    # 1. Backup di Lama
    $SSH_CMD "
        mkdir -p $OLD_BACKUP_DIR
        mysqldump -h $OLD_DB_HOST -u $OLD_DB_USER -p'$OLD_DB_PASS' $OLD_DB_NAME > $OLD_BACKUP_DIR/panel_db_$DATE.sql || exit 1
        tar -czf $OLD_BACKUP_DIR/panel_files_$DATE.tar.gz $OLD_PANEL_PATH || exit 1
        cp $OLD_PANEL_PATH/.env $OLD_BACKUP_DIR/.env_$DATE 2>/dev/null || true
        tar -czf $OLD_BACKUP_DIR/nginx_config_$DATE.tar.gz /etc/nginx/sites-available/pterodactyl* /etc/nginx/nginx.conf 2>/dev/null || true
        echo 'Backup selesai'
    " || error_exit "Gagal backup panel di lama."

    # 2. Transfer
    $SCP_CMD "$SSH_USER@$OLD_IP:$OLD_BACKUP_DIR/*" "$BACKUP_DIR/" || error_exit "Gagal transfer panel."

    # 3. Setup DB Baru
    mysql -h localhost -u root -p"$ROOT_PASS" <<EOF || error_exit "Gagal setup DB panel"
CREATE DATABASE IF NOT EXISTS $DB_NAME;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

    # 4. Restore DB
    DB_FILE="$BACKUP_DIR/panel_db_$DATE.sql"
    mysql -h localhost -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$DB_FILE" || error_exit "Gagal restore DB panel"

    # 5. Restore Files
    FILES_TAR="$BACKUP_DIR/panel_files_$DATE.tar.gz"
    if [ -d "$PANEL_PATH" ]; then rm -rf "$PANEL_PATH"/*; fi
    tar -xzf "$FILES_TAR" -C /var/www/ || error_exit "Gagal restore files panel"
    chown -R www-data:www-data "$PANEL_PATH"
    chmod -R 755 "$PANEL_PATH"

    # 6. Update .env
    ENV_BACKUP=$(ls "$BACKUP_DIR/.env_"* 2>/dev/null | tail -1)
    if [ -n "$ENV_BACKUP" ]; then
        cp "$ENV_BACKUP" "$PANEL_PATH/.env"
        sed -i "s|APP_URL=.*|APP_URL=https://$NEW_DOMAIN|" "$PANEL_PATH/.env"
        sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=$DB_PASS|" "$PANEL_PATH/.env"
        sed -i "s|DB_HOST=.*|DB_HOST=localhost|" "$PANEL_PATH/.env"
    fi

    # 7. Restore Nginx
    NGINX_TAR="$BACKUP_DIR/nginx_config_$DATE.tar.gz"
    if [ -f "$NGINX_TAR" ]; then
        tar -xzf "$NGINX_TAR" -C /etc/nginx/ 2>/dev/null || true
        sed -i "s|server_name .*;|server_name $NEW_DOMAIN;|g" /etc/nginx/sites-available/pterodactyl* 2>/dev/null || true
        nginx -t && systemctl reload nginx || error_exit "Nginx error panel"
    fi

    # 8. Artisan
    cd "$PANEL_PATH"
    php artisan migrate --force || error_exit "Gagal migrate panel"
    php artisan view:clear && php artisan config:cache && php artisan route:cache && php artisan queue:restart

    # Cleanup
    rm -rf "$BACKUP_DIR"
    $SSH_CMD "rm -rf $OLD_BACKUP_DIR" 2>/dev/null || true

    echo "Migrasi Panel Selesai! Restart: systemctl restart nginx mariadb php8.1-fpm"
    echo "Akses: https://$NEW_DOMAIN | Logs: tail -f $PANEL_PATH/storage/logs/laravel.log"
}

# Fungsi Migrasi Wings (input minimal)
migrate_wings() {
    echo "=== MIGRASE WINGS ==="
    echo "Pastikan Panel sudah dimigrasi dulu! Update token node di panel setelah ini."
    
    if [ -z "$OLD_IP" ]; then read -p "IP/Hostname Node Lama: " OLD_IP; fi
    setup_ssh "$OLD_IP" "wings"
    
    # Default paths
    OLD_WINGS_PATH=${OLD_WINGS_PATH:-"/etc/pterodactyl"}
    WINGS_SSL_PORT=${WINGS_SSL_PORT:-"2022"}
    
    # Prompt esensial
    if [ -z "$NEW_FQDN" ]; then read -p "FQDN Node Baru (misal: node.example.com): " NEW_FQDN; fi
    read -s -p "Token Wings Baru (dari panel): " NEW_TOKEN
    echo

    DATE=$(date +%Y%m%d_%H%M%S)
    BACKUP_DIR="/tmp/wings_backup"
    OLD_BACKUP_DIR="/tmp/wings_backup"

    echo "Mulai migrasi wings pada $(date)..."

    # 1. Backup di Lama
    $SSH_CMD "
        mkdir -p $OLD_BACKUP_DIR
        cp $OLD_WINGS_PATH/config.yml $OLD_BACKUP_DIR/config_$DATE.yml || exit 1
        echo 'Backup config.yml selesai'
    " || error_exit "Gagal backup wings di lama."

    # 2. Transfer
    $SCP_CMD "$SSH_USER@$OLD_IP:$OLD_BACKUP_DIR/config_$DATE.yml" "$BACKUP_DIR/" || error_exit "Gagal transfer wings."

    # 3. Install Wings Fresh jika belum
    echo "Install Wings jika belum..."
    if ! command -v wings &> /dev/null; then
        bash <(curl -s https://raw.githubusercontent.com/pterodactyl/wings/master/install.sh) || error_exit "Gagal install Wings"
    fi

    # 4. Stop Wings jika running
    systemctl stop wings 2>/dev/null || true

    # 5. Restore & Update Config
    CONFIG_FILE="$BACKUP_DIR/config_$DATE.yml"
    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" /etc/pterodactyl/config.yml
        sed -i "s|uuid: .*|uuid: $(uuidgen)|" /etc/pterodactyl/config.yml
        sed -i "s|token_id: .*|token_id: \"$(date +%s)\"|" /etc/pterodactyl/config.yml
        sed -i "s|token: .*|token: \"$NEW_TOKEN\"|" /etc/pterodactyl/config.yml
        sed -i "s|fqdn: .*|fqdn: $NEW_FQDN|" /etc/pterodactyl/config.yml
        sed -i "s|ssl:.*|ssl:\n  port: $WINGS_SSL_PORT|" /etc/pterodactyl/config.yml
        chown -R pterodactyl:pterodactyl /etc/pterodactyl /var/lib/pterodactyl /var/run/pterodactyl
        chmod -R 755 /etc/pterodactyl /var/lib/pterodactyl /var/run/pterodactyl
        echo "Config updated. Verifikasi /etc/pterodactyl/config.yml manual jika perlu."
    else
        error_exit "File config tidak ditemukan"
    fi

    # 6. Start Wings
    systemctl daemon-reload
    systemctl enable wings
    systemctl start wings || error_exit "Gagal start Wings"
    systemctl status wings --no-pager -l

    # Cleanup
    rm -rf "$BACKUP_DIR"
    $SSH_CMD "rm -rf $OLD_BACKUP_DIR" 2>/dev/null || true

    echo "Migrasi Wings Selesai!"
    echo "Cek status: systemctl status wings"
    echo "Logs: journalctl -u wings -f"
    echo "Di Panel: Admin > Nodes > Edit node > Pastikan FQDN & token benar."
}

# Menu Utama atau Direct Mode
CHOICE=$1
OLD_IP=$2
NEW_DOMAIN=$3  # Untuk panel

if [[ $CHOICE =~ ^[1-2]$ ]]; then
    # Direct mode: ./script.sh 1 old_ip new_domain
    case $CHOICE in
        1) migrate_panel ;;
        2) migrate_wings ;;
    esac
else
    # Menu interaktif jika tidak ada args
    while true; do
        echo ""
        echo "=== MENU MIGRASE PTERODACTYL ==="
        echo "1. Migrasi Panel"
        echo "2. Migrasi Wings"
        echo "0. Exit"
        echo "Atau jalankan langsung: ./$0 1 old_ip new_domain"
        read -p "Pilih opsi: " CHOICE

        case $CHOICE in
            1) migrate_panel ;;
            2) migrate_wings ;;
            0) echo "Bye!"; exit 0 ;;
            *) echo "Pilihan salah!" ;;
        esac
    done
fi
