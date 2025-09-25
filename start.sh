#!/bin/bash

echo "=== Migrasi Pterodactyl Panel & Wings ==="

# Input
read -p "Masukkan IP VPS Lama: " OLD_IP
read -p "Masukkan Username VPS Lama (default: root): " OLD_USER
OLD_USER=${OLD_USER:-root}
read -sp "Masukkan Password VPS Lama: " OLD_PASS
echo
read -p "Masukkan Domain Panel Baru (atau lama): " PANEL_DOMAIN
read -p "Masukkan Domain Node Baru (atau lama): " NODE_DOMAIN

# Update sistem
apt update -y && apt upgrade -y
apt install -y sshpass rsync curl gnupg2 ca-certificates lsb-release software-properties-common unzip

echo "[1/5] Backup data & database dari VPS Lama..."
sshpass -p "$OLD_PASS" ssh -o StrictHostKeyChecking=no $OLD_USER@$OLD_IP "mysqldump -u root -p --all-databases > /root/panel_db.sql"
sshpass -p "$OLD_PASS" rsync -avz --progress $OLD_USER@$OLD_IP:/var/www/pterodactyl/ /root/panel_files/
sshpass -p "$OLD_PASS" rsync -avz --progress $OLD_USER@$OLD_IP:/etc/pterodactyl/ /root/wings_config/
sshpass -p "$OLD_PASS" rsync -avz --progress $OLD_USER@$OLD_IP:/root/panel_db.sql /root/

echo "[2/5] Install dependency di VPS baru..."
# MariaDB
apt install -y mariadb-server mariadb-client
systemctl enable --now mariadb

# PHP + ext
apt install -y php8.2 php8.2-cli php8.2-gd php8.2-mysql php8.2-mbstring php8.2-bcmath php8.2-xml php8.2-curl php8.2-zip composer unzip tar

# Redis
apt install -y redis-server

# NodeJS terbaru
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

# Nginx
apt install -y nginx certbot python3-certbot-nginx

echo "[3/5] Restore database & file..."
mysql < /root/panel_db.sql
mkdir -p /var/www/pterodactyl
rsync -av /root/panel_files/ /var/www/pterodactyl/
chown -R www-data:www-data /var/www/pterodactyl

# Restore wings config
mkdir -p /etc/pterodactyl
rsync -av /root/wings_config/ /etc/pterodactyl/

echo "[4/5] Konfigurasi Nginx + SSL..."
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
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -s /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# SSL
certbot --nginx -d $PANEL_DOMAIN -n --agree-tos --register-unsafely-without-email

echo "[5/5] Setup Wings service..."
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
ExecStart=/usr/bin/wings
Restart=on-failure
StartLimitInterval=600

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now wings

echo "=== Migrasi selesai! ==="
echo "Panel: https://$PANEL_DOMAIN"
echo "Node: https://$NODE_DOMAIN"
