#!/bin/bash

# Fungsi error handling
error_exit() {
    echo "Error: $1" >&2
    exit 1
}

# Fungsi setup SSH (sama untuk panel & wings)
setup_ssh() {
    local target_ip=$1
    local target_type=$2  # "panel" atau "wings"
    echo "=== Setup SSH untuk $target_type ke $target_ip ==="
    read -p "SSH User (default: root): " SSH_USER
    SSH_USER=${SSH_USER:-"root"}
    read -p "SSH Port (default: 22): " SSH_PORT
    SSH_PORT=${SSH_PORT:-"22"}

    read -p "Pakai SSH Password? (y/n, default: n - asumsi key): " USE_PASS
    if [[ $USE_PASS == "y" || $USE_PASS == "Y" ]]; then
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
    return 0  # Return SSH_CMD dan SCP_CMD via global atau echo, tapi untuk simplicity, define global
}

# Fungsi Migrasi Panel
migrate_panel() {
    echo "=== OPSI 1: MIGRASE PANEL ==="
    read -p "IP/Hostname VPS Lama: " OLD_IP
    setup_ssh "$OLD_IP" "panel"
    # Global vars dari setup_ssh (dalam praktik, define di sini; script ini simplify)

    # Input DB & Path Lama
    read -p "Path Panel Lama (default: /var/www/pterodactyl): " OLD_PANEL_PATH
    OLD_PANEL_PATH=${OLD_PANEL_PATH:-"/var/www/pterodactyl"}
    read -p "DB Host Lama (default: localhost): " OLD_DB_HOST
    OLD_DB_HOST=${OLD_DB_HOST:-"localhost"}
    read -p "DB Username Lama: " OLD_DB_USER
    read -s -p "DB Password Lama: " OLD_DB_PASS
    echo
    read -p "DB Name Lama (default: panel): " OLD_DB_NAME
    OLD_DB_NAME=${OLD_DB_NAME:-"panel"}

    # Input Baru
    read -p "Path Panel Baru (default: /var/www/pterodactyl): " PANEL_PATH
    PANEL_PATH=${PANEL_PATH:-"/var/www/pterodactyl"}
    read -s -p "MySQL Root Password Baru: " ROOT_PASS
    echo
    read -p "DB Username Baru (default: pterodactyl): " DB_USER
    DB_USER=${DB_USER:-"pterodactyl"}
    read -s -p "DB Password Baru: " DB_PASS
    echo
    read -p "DB Name Baru (default: panel): " DB_NAME
    DB_NAME=${DB_NAME:-"panel"}
    read -p "Domain/IP Baru: " NEW_DOMAIN

    DATE=$(date +%Y%m%d_%H%M%S)
    BACKUP_DIR="/tmp/pterodactyl_backup"
    OLD_BACKUP_DIR="/tmp/pterodactyl_backup"

    echo "Mulai migrasi panel pada $(date)..."

    # 1. Backup di Lama
    $SSH_CMD "
        mkdir -p $OLD_BACKUP_DIR
        mysqldump -h $OLD_DB_HOST -u $OLD_DB_USER -p'$OLD_DB_PASS' $OLD_DB_NAME > $OLD_BACKUP_DIR/panel_db_$DATE.sql || exit 1
        tar -czf $OLD_BACKUP_DIR/panel_files_$DATE.tar.gz $OLD_PANEL_PATH || exit 1
        cp $OLD_PANEL_PATH/.env $OLD_BACKUP_DIR/.env_$DATE 2>/dev/null
        tar -czf $OLD_BACKUP_DIR/nginx_config_$DATE.tar.gz /etc/nginx/sites-available/pterodactyl* /etc/nginx/nginx.conf 2>/dev/null
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
        tar -xzf "$NGINX_TAR" -C /etc/nginx/ 2>/dev/null
        sed -i "s|server_name .*;|server_name $NEW_DOMAIN;|g" /etc/nginx/sites-available/pterodactyl* 2>/dev/null
        nginx -t && systemctl reload nginx || error_exit "Nginx error panel"
    fi

    # 8. Artisan
    cd "$PANEL_PATH"
    php artisan migrate --force || error_exit "Gagal migrate panel"
    php artisan view:clear && php artisan config:cache && php artisan route:cache && php artisan queue:restart

    # Cleanup
    rm -rf "$BACKUP_DIR"
    $SSH_CMD "rm -rf $OLD_BACKUP_DIR" 2>/dev/null

    echo "Migrasi Panel Selesai! Restart: systemctl restart nginx mariadb php8.1-fpm"
    echo "Akses: https://$NEW_DOMAIN | Logs: tail -f $PANEL_PATH/storage/logs/laravel.log"
}

# Fungsi Migrasi Wings
migrate_wings() {
    echo "=== OPSI 2: MIGRASE WINGS (Node Daemon) ==="
    echo "Pastikan Panel sudah dimigrasi dulu! Update token node di panel setelah ini."
    read -p "IP/Hostname Node Lama: " OLD_IP
    setup_ssh "$OLD_IP" "wings"

    # Input Path Lama
    read -p "Path Wings Lama (default: /etc/pterodactyl): " OLD_WINGS_PATH
    OLD_WINGS_PATH=${OLD_WINGS_PATH:-"/etc/pterodactyl"}

    # Input Baru
    read -p "FQDN Node Baru (untuk config, misal: node.example.com): " NEW_FQDN
    read -p "Token Wings Baru (dari panel Admin > Nodes > Regenerate, wajib input manual setelah migrasi panel): " NEW_TOKEN
    read -p "Port SSL Wings (default: 2022): " WINGS_SSL_PORT
    WINGS_SSL_PORT=${WINGS_SSL_PORT:-"2022"}

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

    # 3. Install Wings Fresh di Baru (jika belum)
    echo "Install Wings jika belum..."
    if ! command -v wings &> /dev/null; then
        bash <(curl -s https://raw.githubusercontent.com/pterodactyl/wings/master/install.sh) || error_exit "Gagal install Wings"
    fi

    # 4. Stop Wings jika running
    systemctl stop wings 2>/dev/null

    # 5. Restore & Update Config
    CONFIG_FILE="$BACKUP_DIR/config_$DATE.yml"
    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" /etc/pterodactyl/config.yml
        # Update config untuk baru (ganti FQDN, token, port)
        sed -i "s|uuid: .*|uuid: $(uuidgen)|" /etc/pterodactyl/config.yml  # New UUID
        sed -i "s|token_id: .*|token_id: \"$(date +%s)\"|" /etc/pterodactyl/config.yml  # New token_id
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
    $SSH_CMD "rm -rf $OLD_BACKUP_DIR" 2>/dev/null

    echo "Migrasi Wings Selesai!"
    echo "Cek status: systemctl status wings"
    echo "Logs: journalctl -u wings -f"
    echo "Di Panel: Admin > Nodes > Edit node > Pastikan FQDN & token benar. Regenerate token jika ganti."
    echo "Test: Buat server test di panel, assign ke node ini."
}

# Menu Utama
while true; do
    echo ""
    echo "=== MENU MIGRASE PTERODACTYL ==="
    echo "1. Migrasi Panel (VPS lama ke baru)"
    echo "2. Migrasi Wings (Node lama ke baru)"
    echo "0. Exit"
    read -p "Pilih opsi: " CHOICE

    case $CHOICE in
        1) migrate_panel ;;
        2) migrate_wings ;;
        0) echo "Bye!"; exit 0 ;;
        *) echo "Pilihan salah!" ;;
    esac
done
