#!/bin/bash

echo "=== Migrasi Panel Pterodactyl ==="

# Input yang dibutuhkan
read -p "Masukkan IP VPS Lama: " OLD_IP
read -p "Masukkan User VPS Lama (biasanya root): " OLD_USER
read -sp "Masukkan Password VPS Lama: " OLD_PASS
echo
read -p "Masukkan Nama Database Pterodactyl (default: panel): " DB_NAME
DB_NAME=${DB_NAME:-panel}
read -p "Masukkan Domain untuk Panel (misal: panel.domainkamu.com): " DOMAIN

# Folder utama pterodactyl
PTERO_PATH="/var/www/pterodactyl"

# Install dependensi di VPS baru
echo "[+] Install dependensi (zip, sshpass, mariadb-client, nginx, certbot)..."
apt update -y && apt install -y sshpass zip mariadb-client nginx certbot python3-certbot-nginx

# Backup file & database di VPS lama
echo "[+] Backup database dan file di VPS lama..."
sshpass -p "$OLD_PASS" ssh -o StrictHostKeyChecking=no $OLD_USER@$OLD_IP " \
    mysqldump -u root -p$OLD_PASS $DB_NAME > /root/ptero.sql && \
    cd /var/www && tar -czf /root/ptero-files.tar.gz pterodactyl"

# Copy backup ke VPS baru
echo "[+] Transfer backup ke VPS baru..."
sshpass -p "$OLD_PASS" scp -o StrictHostKeyChecking=no $OLD_USER@$OLD_IP:/root/ptero.sql /root/
sshpass -p "$OLD_PASS" scp -o StrictHostKeyChecking=no $OLD_USER@$OLD_IP:/root/ptero-files.tar.gz /root/

# Restore file
echo "[+] Restore file ke VPS baru..."
mkdir -p /var/www
tar -xzf /root/ptero-files.tar.gz -C /var/www/

# Perbaiki permission
chown -R www-data:www-data $PTERO_PATH
chmod -R 755 $PTERO_PATH

# Buat database jika belum ada
echo "[+] Membuat database jika belum ada..."
mysql -u root -p -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;"

# Restore database
echo "[+] Restore database..."
mysql -u root -p $DB_NAME < /root/ptero.sql

# Buat config Nginx
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
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock; # sesuaikan versi PHP
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

# Pasang SSL
echo "[+] Pasang SSL Let's Encrypt..."
certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN || true

echo "=== Migrasi selesai! ==="
echo "Sekarang ubah DNS A record di Cloudflare:"
echo "$DOMAIN → IP VPS baru ini"
echo "Cek config database di: $PTERO_PATH/.env"
