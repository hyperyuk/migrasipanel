#!/bin/bash
# =====================================================
# Auto Install & Migrasi Pterodactyl Panel + Node (Wings)
# Tested on Ubuntu 20.04/22.04
# =====================================================

# Pastikan dijalankan sebagai root
if [ "$EUID" -ne 0 ]; then
  echo "Harus dijalankan sebagai root"
  exit
fi

# Input sederhana
read -p "Masukkan domain untuk panel (contoh: panel.domain.com): " PANEL_DOMAIN
read -p "Masukkan email admin untuk Let's Encrypt: " ADMIN_EMAIL
read -p "Masukkan IP server (untuk wings node): " NODE_IP

# Opsi migrasi Wings dari VPS lama
read -p "Apakah ingin copy Wings config + data dari VPS lama? (y/n): " COPY_WINGS

if [ "$COPY_WINGS" == "y" ]; then
    read -p "Masukkan IP VPS lama: " OLD_IP
    read -p "Masukkan user SSH VPS lama (default: root): " OLD_USER
    OLD_USER=${OLD_USER:-root}
fi

# Update sistem
echo "[+] Update sistem..."
apt update -y && apt upgrade -y

# Install dependensi dasar
echo "[+] Install dependensi..."
apt install -y software-properties-common curl apt-transport-https ca-certificates gnupg unzip git ufw rsync

# Install MariaDB, Redis, PHP, Composer, Nginx, NodeJS, Certbot
echo "[+] Install MariaDB, Redis, PHP, Nginx, NodeJS..."
apt install -y mariadb-server redis-server nginx certbot python3-certbot-nginx

# PHP repo
LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
apt update
apt install -y php8.1 php8.1-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,curl,zip,fpm}

# Install Composer & NodeJS
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
curl -fsSL https://deb.nodesource.com/setup_16.x | bash -
apt install -y nodejs

# Setup database
echo "[+] Membuat database pterodactyl..."
DB_PASS=$(openssl rand -base64 12)
DB_USER=ptero
DB_NAME=pterodb

mysql -u root <<MYSQL_SCRIPT
CREATE DATABASE ${DB_NAME};
CREATE USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
MYSQL_SCRIPT

echo "Database: ${DB_NAME}, User: ${DB_USER}, Password: ${DB_PASS}" > /root/pterodactyl_db.txt

# Install panel
echo "[+] Install Pterodactyl Panel..."
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz && rm panel.tar.gz
cp .env.example .env

composer install --no-dev --optimize-autoloader
php artisan key:generate --force

# Konfigurasi .env otomatisised
sed -i "s/DB_DATABASE=.*/DB_DATABASE=${DB_NAME}/" .env
sed -i "s/DB_USERNAME=.*/DB_USERNAME=${DB_USER}/" .env
sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=${DB_PASS}/" .env

# Migrasi database
php artisan migrate --seed --force

# Permission
chown -R www-data:www-data /var/www/pterodactyl/*

# Konfigurasi Nginx
cat > /etc/nginx/sites-available/pterodactyl.conf <<EOL
server {
    listen 80;
    server_name ${PANEL_DOMAIN};
    root /var/www/pterodactyl/public;

    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_index index.php;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOL

ln -s /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# SSL Let's Encrypt
echo "[+] Setup SSL..."
certbot --nginx -d ${PANEL_DOMAIN} --non-interactive --agree-tos -m ${ADMIN_EMAIL}

# Install Wings (Node)
echo "[+] Install Wings Node..."
mkdir -p /etc/pterodactyl
curl -Lo /usr/local/bin/wings https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64
chmod +x /usr/local/bin/wings

# Systemd service untuk wings
cat > /etc/systemd/system/wings.service <<EOL
[Unit]
Description=Pterodactyl Wings Daemon
After=network.target

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30

[Install]
WantedBy=multi-user.target
EOL

systemctl enable --now wings

# Migrasi Wings dari VPS lama (jika dipilih)
if [ "$COPY_WINGS" == "y" ]; then
    echo "[+] Copy config.yml dari VPS lama..."
    rsync -avz ${OLD_USER}@${OLD_IP}:/etc/pterodactyl/config.yml /etc/pterodactyl/config.yml

    echo "[+] Copy data server (bisa agak lama tergantung ukuran)..."
    rsync -avz --progress ${OLD_USER}@${OLD_IP}:/var/lib/pterodactyl/ /var/lib/pterodactyl/

    chown -R root:root /etc/pterodactyl /var/lib/pterodactyl
    systemctl restart wings
    echo "[+] Migrasi Wings selesai, data sudah dipindahkan."
fi

# UFW rules
echo "[+] Konfigurasi firewall..."
ufw allow OpenSSH
ufw allow 80
ufw allow 443
ufw allow 8080
ufw allow 2022
ufw --force enable

# Selesai
echo "=============================================="
echo "Pterodactyl Panel selesai diinstall!"
echo "URL: https://${PANEL_DOMAIN}"
echo "Database info tersimpan di: /root/pterodactyl_db.txt"
echo "Node (Wings) berjalan di IP: ${NODE_IP}"
