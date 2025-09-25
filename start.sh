#!/bin/bash
set -euo pipefail

echo "=== Pterodactyl Auto Migration Script ==="

# === INPUT ===
read -p "IP VPS Lama: " OLD_IP
read -p "User VPS Lama (default: root): " OLD_USER
OLD_USER=${OLD_USER:-root}
read -sp "Password VPS Lama: " OLD_PASS
echo
read -p "Domain Panel Baru (contoh: panel.domain.com): " PANEL_DOMAIN
read -p "Domain Node Baru (contoh: node.domain.com): " NODE_DOMAIN

# === UPDATE VPS BARU ===
echo "[1/8] Update & install dependencies..."
apt update -y
apt upgrade -y
apt install -y curl wget git unzip tar lsb-release apt-transport-https software-properties-common gnupg2 \
    mariadb-server mariadb-client redis-server certbot python3-certbot-nginx composer nodejs npm \
    php-cli php-mysql php-gd php-mbstring php-bcmath php-xml php-curl php-zip php-fpm php-intl \
    nginx sshpass docker.io

systemctl enable --now mariadb redis-server docker

# === BACKUP DARI VPS LAMA ===
echo "[2/8] Backup dari VPS lama..."
sshpass -p "$OLD_PASS" ssh -o StrictHostKeyChecking=no $OLD_USER@$OLD_IP "mysqldump -u root panel > /root/panel.sql"
sshpass -p "$OLD_PASS" scp -o StrictHostKeyChecking=no $OLD_USER@$OLD_IP:/root/panel.sql /root/panel.sql
sshpass -p "$OLD_PASS" scp -o StrictHostKeyChecking=no -r $OLD_USER@$OLD_IP:/var/www/pterodactyl /root/pterodactyl_old
sshpass -p "$OLD_PASS" scp -o StrictHostKeyChecking=no -r $OLD_USER@$OLD_IP:/etc/pterodactyl /root/wings_old || true

# === RESTORE DATABASE ===
echo "[3/8] Restore database..."
mysql -u root -e "CREATE DATABASE IF NOT EXISTS panel;"
mysql -u root panel < /root/panel.sql

# === RESTORE FILES ===
echo "[4/8] Restore panel files..."
rm -rf /var/www/pterodactyl
cp -r /root/pterodactyl_old /var/www/pterodactyl
chown -R www-data:www-data /var/www/pterodactyl
chmod -R 755 /var/www/pterodactyl

# === SETUP COMPOSER & ARTISAN ===
echo "[5/8] Setup composer & artisan..."
cd /var/www/pterodactyl
composer install --no-dev --optimize-autoloader
npm install --production
php artisan key:generate --force || true
php artisan migrate --force
php artisan config:cache
php artisan view:cache
php artisan route:cache

# === SETUP NGINX + SSL ===
echo "[6/8] Setup Nginx & SSL..."
cat > /etc/nginx/sites-available/pterodactyl <<EOF
server {
    listen 80;
    server_name $PANEL_DOMAIN;
    root /var/www/pterodactyl/public;

    index index.php;
    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -sf /etc/nginx/sites-available/pterodactyl /etc/nginx/sites-enabled/pterodactyl
nginx -t && systemctl restart nginx
certbot --nginx -d $PANEL_DOMAIN -d $NODE_DOMAIN --non-interactive --agree-tos -m admin@$PANEL_DOMAIN || true

# === RESTORE WINGS ===
echo "[7/8] Restore wings..."
mkdir -p /etc/pterodactyl
if [ -d "/root/wings_old" ]; then
    cp -r /root/wings_old/* /etc/pterodactyl/
fi

cat > /etc/systemd/system/wings.service <<EOF
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
ExecStart=/usr/local/bin/wings
Restart=on-failure
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now wings || true

# === DONE ===
echo "[8/8] Migration Selesai!"
echo "Panel URL: https://$PANEL_DOMAIN"
echo "Node URL: https://$NODE_DOMAIN"
echo "Login dengan akun admin lama atau buat baru via:"
echo "cd /var/www/pterodactyl && php artisan p:user:make"
