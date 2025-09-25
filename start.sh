#!/bin/bash
set -e

echo "=== Migrasi Pterodactyl Panel + Wings ==="

# Input
read -p "Masukkan IP VPS Lama: " OLD_IP
read -p "Masukkan Username VPS Lama (default: root): " OLD_USER
OLD_USER=${OLD_USER:-root}
read -sp "Masukkan Password VPS Lama: " OLD_PASS
echo
read -p "Masukkan Domain Panel Baru (atau lama): " PANEL_DOMAIN
read -p "Masukkan Domain Node Baru (atau lama): " NODE_DOMAIN

echo "[1/6] Update VPS baru..."
apt update -y && apt upgrade -y
apt install -y sshpass rsync curl gnupg2 ca-certificates lsb-release software-properties-common unzip mariadb-server mariadb-client redis-server nginx certbot python3-certbot-nginx

echo "[2/6] Ambil file panel & config dari VPS lama..."
sshpass -p "$OLD_PASS" rsync -avz --progress $OLD_USER@$OLD_IP:/var/www/pterodactyl/ /root/panel_files/
sshpass -p "$OLD_PASS" rsync -avz --progress $OLD_USER@$OLD_IP:/etc/pterodactyl/ /root/wings_config/
sshpass -p "$OLD_PASS" ssh -o StrictHostKeyChecking=no $OLD_USER@$OLD_IP "mysqldump -u root --all-databases > /root/panel_db.sql"
sshpass -p "$OLD_PASS" rsync -avz --progress $OLD_USER@$OLD_IP:/root/panel_db.sql /root/

echo "[3/6] Restore panel files..."
mkdir -p /var/www/pterodactyl
rsync -av /root/panel_files/ /var/www/pterodactyl/
chown -R www-data:www-data /var/www/pterodactyl

echo "[4/6] Setup database..."
mysql -u root <<EOF
DROP DATABASE IF EXISTS panel;
CREATE DATABASE panel;
EOF

# Baca user & password dari .env
DB_USER=$(grep DB_USERNAME /var/www/pterodactyl/.env | cut -d '=' -f2)
DB_PASS=$(grep DB_PASSWORD /var/www/pterodactyl/.env | cut -d '=' -f2)

mysql -u root <<EOF
DROP USER IF EXISTS '$DB_USER'@'127.0.0.1';
CREATE USER '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON panel.* TO '$DB_USER'@'127.0.0.1';
FLUSH PRIVILEGES;
EOF

# Import DB lama
mysql -u root panel < /root/panel_db.sql || true

echo "[5/6] Konfigurasi Nginx + SSL..."
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

ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
nginx -t && systemctl reload nginx

# SSL otomatis
certbot --nginx -d $PANEL_DOMAIN -n --agree-tos --register-unsafely-without-email || true

echo "[6/6] Setup Wings..."
# Install Wings binary terbaru
curl -L https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64 -o /usr/bin/wings
chmod +x /usr/bin/wings

mkdir -p /etc/pterodactyl
rsync -av /root/wings_config/ /etc/pterodactyl/

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

echo "=== Migrasi Selesai ==="
echo "Panel: https://$PANEL_DOMAIN"
echo "Node: https://$NODE_DOMAIN"
echo "Silakan jalankan: cd /var/www/pterodactyl && php artisan p:user:make"
