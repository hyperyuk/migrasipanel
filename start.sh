#!/bin/bash
set -e

echo "=== Migrasi Panel Pterodactyl ==="

# === INPUT DARI USER ===
read -p "Masukkan IP VPS Lama: " OLD_IP
read -p "Masukkan User VPS Lama (default: root): " OLD_USER
OLD_USER=${OLD_USER:-root}
read -sp "Masukkan Password VPS Lama: " OLD_PASS
echo
read -p "Masukkan Domain Baru (ex: panel.domain.com): " NEW_DOMAIN
read -p "Masukkan MySQL root password baru: " MYSQL_PASS

# === UPDATE SISTEM & INSTALL DEPENDENSI ===
apt update -y
apt upgrade -y
apt install -y curl wget unzip tar gnupg lsb-release ca-certificates apt-transport-https software-properties-common ufw

# Install MariaDB, Redis, PHP, Composer, Nginx
apt install -y mariadb-server redis-server nginx certbot python3-certbot-nginx php-cli php-mysql php-gd php-mbstring php-bcmath php-xml composer

# Install Docker untuk Wings
apt install -y docker.io
systemctl enable --now docker

# === FIREWALL ===
ufw allow ssh
ufw allow http
ufw allow https
ufw --force enable

# === FIX NGINX DEFAULT ===
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80 default_server;
    server_name _;
    root /var/www/html;
    index index.html;
}
EOF
ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx

# === SETUP DATABASE ===
systemctl enable --now mariadb
mysql -u root <<MYSQL_SCRIPT
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_PASS}';
FLUSH PRIVILEGES;
CREATE DATABASE IF NOT EXISTS panel;
MYSQL_SCRIPT

# === AMBIL FILE DARI VPS LAMA ===
echo "=== Migrasi file dari VPS lama ==="
sshpass -p "${OLD_PASS}" rsync -avz -e ssh ${OLD_USER}@${OLD_IP}:/var/www/pterodactyl/ /var/www/pterodactyl/
sshpass -p "${OLD_PASS}" rsync -avz -e ssh ${OLD_USER}@${OLD_IP}:/etc/pterodactyl/ /etc/pterodactyl/ || true

# === AMBIL DATABASE DARI VPS LAMA ===
sshpass -p "${OLD_PASS}" ssh ${OLD_USER}@${OLD_IP} "mysqldump -u root panel --password=${MYSQL_PASS}" > /tmp/panel.sql
mysql -u root -p${MYSQL_PASS} panel < /tmp/panel.sql

# === SETUP .ENV JIKA HILANG ===
if [ ! -f /var/www/pterodactyl/.env ]; then
cat > /var/www/pterodactyl/.env <<EOF
APP_ENV=production
APP_DEBUG=false
APP_URL=https://${NEW_DOMAIN}
APP_TIMEZONE=Asia/Jakarta

DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=panel
DB_USERNAME=root
DB_PASSWORD=${MYSQL_PASS}

CACHE_DRIVER=redis
SESSION_DRIVER=redis
QUEUE_DRIVER=redis

REDIS_HOST=127.0.0.1
REDIS_PASSWORD=null
REDIS_PORT=6379
EOF
fi

chown -R www-data:www-data /var/www/pterodactyl
cd /var/www/pterodactyl && composer install --no-dev --optimize-autoloader

# === SETUP NGINX UNTUK PANEL ===
cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    listen 80;
    server_name ${NEW_DOMAIN};

    root /var/www/pterodactyl/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.access.log;
    error_log  /var/log/nginx/pterodactyl.error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
}
EOF

ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
nginx -t && systemctl restart nginx

# === SSL LETSENCRYPT ===
certbot --nginx -d ${NEW_DOMAIN} --non-interactive --agree-tos -m admin@${NEW_DOMAIN}

# === SETUP WINGS ===
mkdir -p /etc/pterodactyl
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
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30

[Install]
WantedBy=multi-user.target
EOF

systemctl enable --now wings

echo "=== Migrasi selesai! ==="
echo "Login panel di: https://${NEW_DOMAIN}"
echo "MySQL root password: ${MYSQL_PASS}"
