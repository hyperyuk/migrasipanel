#!/bin/bash
# ==========================================
# Script Migrasi Pterodactyl Panel & Wings
# By Ryunitro (Final Version + UFW)
# ==========================================

echo "======================================="
echo "      Script Migrasi Pterodactyl"
echo "======================================="

# Input VPS lama
read -p "Masukkan IP VPS Lama: " OLD_IP
read -p "Masukkan User VPS Lama (default: root): " OLD_USER
OLD_USER=${OLD_USER:-root}
read -sp "Masukkan Password VPS Lama: " OLD_PASS
echo
read -p "Masukkan Nama Database Pterodactyl (default: panel): " DB_NAME
DB_NAME=${DB_NAME:-panel}
read -sp "Masukkan Password MySQL root VPS Baru: " MYSQL_PASS
echo
read -p "Masukkan Domain untuk Panel (misal: panel.domainkamu.com): " DOMAIN

# Opsi migrasi
echo "Pilih opsi migrasi:"
echo "1. Migrasi Panel saja"
echo "2. Migrasi Wings saja"
echo "3. Migrasi Panel + Wings"
read -p "Masukkan pilihan (1/2/3): " choice

# Folder utama
BACKUP_DIR="/root/migrasi"
PTERO_PATH="/var/www/pterodactyl"
mkdir -p $BACKUP_DIR

# Install dependensi
echo "[+] Install dependensi..."
apt update -y && apt install -y sshpass zip mariadb-client nginx certbot python3-certbot-nginx ufw

# Auto detect PHP-FPM socket
PHP_SOCK=$(ls /var/run/php/php*-fpm.sock | head -n1)

# === MIGRASI PANEL ===
migrasi_panel() {
    echo "[*] Migrasi Panel..."
    sshpass -p "$OLD_PASS" ssh -o StrictHostKeyChecking=no $OLD_USER@$OLD_IP " \
        mysqldump -u root -p$OLD_PASS $DB_NAME > /root/panel.sql && \
        cd /var/www && tar -czf /root/panel-files.tar.gz pterodactyl" || { echo "Gagal backup panel di VPS lama!"; exit 1; }

    sshpass -p "$OLD_PASS" scp -o StrictHostKeyChecking=no $OLD_USER@$OLD_IP:/root/panel.sql $BACKUP_DIR/ || exit 1
    sshpass -p "$OLD_PASS" scp -o StrictHostKeyChecking=no $OLD_USER@$OLD_IP:/root/panel-files.tar.gz $BACKUP_DIR/ || exit 1

    mkdir -p /var/www
    tar -xzf $BACKUP_DIR/panel-files.tar.gz -C /var/www/

    chown -R www-data:www-data $PTERO_PATH
    chmod -R 755 $PTERO_PATH

    echo "[+] Membuat database jika belum ada..."
    mysql -u root -p$MYSQL_PASS -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;"

    echo "[+] Restore database..."
    mysql -u root -p$MYSQL_PASS $DB_NAME < $BACKUP_DIR/panel.sql

    echo "[+] Membuat konfigurasi nginx..."
    cat > /etc/nginx/sites-available/pterodactyl.conf <<EOL
server {
    listen 80;
    server_name $DOMAIN;

    root /var/www/pterodactyl/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.access.log;
    error_log  /var/log/nginx/pterodactyl.error.log error;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:$PHP_SOCK;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL

    ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/
    nginx -t && systemctl restart nginx

    echo "[+] Reload PHP-FPM..."
    systemctl restart php*-fpm || true

    echo "[+] Pasang SSL Let's Encrypt..."
    certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN || true

    echo "[✓] Migrasi Panel selesai!"
}

# === MIGRASI WINGS ===
migrasi_wings() {
    echo "[*] Migrasi Wings..."
    sshpass -p "$OLD_PASS" ssh -o StrictHostKeyChecking=no $OLD_USER@$OLD_IP " \
        tar -czf /root/wings-files.tar.gz /etc/pterodactyl /var/lib/pterodactyl" || { echo "Gagal backup wings di VPS lama!"; exit 1; }

    sshpass -p "$OLD_PASS" scp -o StrictHostKeyChecking=no $OLD_USER@$OLD_IP:/root/wings-files.tar.gz $BACKUP_DIR/ || exit 1

    tar -xzf $BACKUP_DIR/wings-files.tar.gz -C /

    systemctl daemon-reexec
    systemctl enable --now wings

    echo "[✓] Migrasi Wings selesai!"
}

# === FIREWALL UFW ===
setup_ufw() {
    echo "[+] Konfigurasi UFW..."
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw allow 80
    ufw allow 443
    ufw allow 2022
    ufw allow 8080
    ufw allow 30000:35000/tcp
    ufw allow 30000:35000/udp
    ufw --force enable
    echo "[✓] UFW aktif dan dikonfigurasi."
}

# Eksekusi sesuai pilihan
case $choice in
    1) migrasi_panel ;;
    2) migrasi_wings ;;
    3) migrasi_panel; migrasi_wings ;;
    *) echo "Pilihan tidak valid!"; exit 1 ;;
esac

setup_ufw

echo "======================================="
echo " Migrasi selesai!"
echo "Cek config database di: $PTERO_PATH/.env"
echo "Pastikan DNS domain $DOMAIN sudah mengarah ke IP VPS baru."
echo "Cek log: journalctl -u nginx -u wings -f"
echo "======================================="
