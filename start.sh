#!/bin/bash

echo "=== Migrasi Panel Pterodactyl ==="

# Input data
read -p "Masukkan IP VPS Lama: " OLD_IP
read -p "Masukkan User VPS Lama (default: root): " OLD_USER
OLD_USER=${OLD_USER:-root}
read -sp "Masukkan Password VPS Lama: " OLD_PASS
echo
read -p "Masukkan Domain Panel (contoh: panel.domain.com): " NEW_DOMAIN

# Lokasi backup
BACKUP_DIR="/root/pterodactyl-backup"
mkdir -p $BACKUP_DIR

echo "=== Instal dependency di VPS baru ==="
apt update -y
apt install -y sshpass rsync mariadb-server nginx redis-server php-cli unzip curl

echo "=== Ambil backup dari VPS lama ==="
sshpass -p "$OLD_PASS" ssh -o StrictHostKeyChecking=no $OLD_USER@$OLD_IP "mysqldump -u root -p panel > /root/panel.sql"
sshpass -p "$OLD_PASS" scp -o StrictHostKeyChecking=no $OLD_USER@$OLD_IP:/root/panel.sql $BACKUP_DIR/panel.sql
sshpass -p "$OLD_PASS" rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" $OLD_USER@$OLD_IP:/var/www/pterodactyl/ $BACKUP_DIR/pterodactyl/

echo "=== Restore database ke VPS baru ==="
mysql -u root -e "CREATE DATABASE IF NOT EXISTS panel"
mysql -u root panel < $BACKUP_DIR/panel.sql

echo "=== Restore file panel ke VPS baru ==="
mkdir -p /var/www/pterodactyl
rsync -avz $BACKUP_DIR/pterodactyl/ /var/www/pterodactyl/

echo "=== Set permission ==="
chown -R www-data:www-data /var/www/pterodactyl
chmod -R 755 /var/www/pterodactyl

echo "=== Setup Nginx ==="
cat > /etc/nginx/sites-available/pterodactyl.conf <<EOL
server {
    listen 80;
    server_name $NEW_DOMAIN;

    root /var/www/pterodactyl/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.access.log;
    error_log  /var/log/nginx/pterodactyl.error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL

ln -s /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/
systemctl restart nginx
systemctl restart php8.1-fpm

echo "=== Migrasi selesai! ==="
echo "Akses panel di: http://$NEW_DOMAIN"
