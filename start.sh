#!/bin/bash
set -e

echo "=== MIGRASI PANEL PTERODACTYL ==="

# ======================
# INPUT USER
# ======================
read -p "IP VPS Lama: " OLD_IP
read -p "Username VPS Lama (biasanya root): " OLD_USER
read -sp "Password VPS Lama: " OLD_PASS
echo
read -p "Domain Panel Baru (atau lama): " PANEL_DOMAIN
read -p "Domain Node/Wings Baru (atau lama): " NODE_DOMAIN

# ======================
# UPDATE & INSTALL TOOLS
# ======================
apt update -y && apt upgrade -y
apt install -y sshpass rsync curl unzip git gnupg2 ca-certificates lsb-release apt-transport-https software-properties-common \
 mariadb-server redis-server nginx certbot python3-certbot-nginx php-cli php-mysql php-redis php-gd php-mbstring php-bcmath php-xml composer nodejs npm docker.io

systemctl enable --now mariadb redis-server docker

# ======================
# COPY FILE DARI VPS LAMA
# ======================
echo ">>> Copy file dari VPS lama..."
sshpass -p "$OLD_PASS" rsync -avz -e "ssh -o StrictHostKeyChecking=no" $OLD_USER@$OLD_IP:/var/www/pterodactyl /var/www/
sshpass -p "$OLD_PASS" rsync -avz -e "ssh -o StrictHostKeyChecking=no" $OLD_USER@$OLD_IP:/etc/pterodactyl /etc/
sshpass -p "$OLD_PASS" rsync -avz -e "ssh -o StrictHostKeyChecking=no" $OLD_USER@$OLD_IP:/var/lib/pterodactyl /var/lib/

# ======================
# RESTORE DATABASE
# ======================
echo ">>> Backup database dari VPS lama..."
sshpass -p "$OLD_PASS" ssh -o StrictHostKeyChecking=no $OLD_USER@$OLD_IP "mysqldump -u root panel > /root/panel.sql"

echo ">>> Copy database ke VPS baru..."
sshpass -p "$OLD_PASS" scp -o StrictHostKeyChecking=no $OLD_USER@$OLD_IP:/root/panel.sql /root/panel.sql

echo ">>> Import database ke MariaDB..."
mysql -u root <<EOF
DROP DATABASE IF EXISTS panel;
CREATE DATABASE panel;
SOURCE /root/panel.sql;
EOF

# ======================
# FIX PERMISSIONS
# ======================
chown -R www-data:www-data /var/www/pterodactyl
chmod -R 755 /var/www/pterodactyl

# ======================
# NGINX CONFIG
# ======================
echo ">>> Setup Nginx..."
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    listen 80;
    server_name $PANEL_DOMAIN;

    root /var/www/pterodactyl/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.access.log;
    error_log  /var/log/nginx/pterodactyl.error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
nginx -t && systemctl restart nginx

# ======================
# SSL CERTIFICATE
# ======================
echo ">>> Pasang SSL Let's Encrypt..."
certbot --nginx -d $PANEL_DOMAIN -d $NODE_DOMAIN --non-interactive --agree-tos -m admin@$PANEL_DOMAIN || true

# ======================
# ARTISAN SETUP
# ======================
cd /var/www/pterodactyl
composer install --no-dev -o
php artisan key:generate --force
php artisan migrate --force
php artisan config:cache
php artisan route:cache
php artisan view:cache

# ======================
# WINGS SETUP
# ======================
echo ">>> Setup Wings..."
mkdir -p /etc/pterodactyl /var/lib/pterodactyl
curl -L https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64 -o /usr/local/bin/wings
chmod +x /usr/local/bin/wings

cat > /etc/systemd/system/wings.service <<EOF
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl enable --now wings

echo "=== MIGRASI SELESAI 🎉 ==="
echo "Panel: https://$PANEL_DOMAIN"
echo "Node:  https://$NODE_DOMAIN"
