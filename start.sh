#!/bin/bash

# Script Bash Lengkap untuk Migrasi Pterodactyl Panel + Wings (Single Node Setup, Domain Tetap Sama)
# Asumsi: 
# - Dijalankan di VPS BARU (Ubuntu/Debian 22.04+ direkomendasikan) sebagai root.
# - VPS lama punya Pterodactyl Panel DAN Wings di node yang sama (single server setup).
# - Akses SSH ke VPS lama dengan user 'root' dan password (tidak aman; gunakan key jika bisa).
# - VPS baru kosong; script akan install Panel + Wings otomatis.
# - Domain tetap sama; script set APP_URL & Wings URL ke domain (ubah DNS Cloudflare ke IP baru setelah migrasi).
# - Backup SEMUA: Panel DB/files/configs, Wings config/binary, volumes (data server game - bisa besar!).
# - Volumes (/var/lib/pterodactyl/volumes) dibackup penuh; siapkan space cukup di VPS baru.
# - Setelah migrasi, edit node di panel jika perlu (tapi domain sama, Wings connect otomatis via domain).
# - Fokus single node; untuk multi-node, migrasi Wings per-node manual.
# - Dependencies: Script install otomatis (nginx, php8.1+, mariadb, redis, wings, etc.).
# - Nginx, PHP-FPM, Supervisor, Cron, Queue, Wings systemd otomatis dikonfigurasi.
# - DB kredensial standar; password DB input saja (sama untuk lama & baru).
# - Admin user baru dibuat otomatis.
# - Jalankan: wget -O migrasi_pterodactyl_full.sh [URL_SCRIPT] && chmod +x migrasi_pterodactyl_full.sh && sudo ./migrasi_pterodactyl_full.sh
# - Warning: Volumes bisa GBs; koneksi stabil. Backup manual tambahan jika ragu! Setelah selesai, ubah DNS di Cloudflare ke IP VPS baru.

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== Script Migrasi Lengkap Pterodactyl Panel + Wings (Domain Tetap Sama) ===${NC}"
echo -e "${YELLOW}Warning: Ini untuk single node setup. Volumes besar - pastikan space & bandwidth cukup.${NC}"
echo -e "${YELLOW}Setelah migrasi, ubah DNS A record di Cloudflare ke IP VPS baru agar domain point ke sini.${NC}"
echo -e "${RED}Jalankan sebagai root! Backup tambahan manual jika multi-node.${NC}"

# Input simple dari user (minimal, tambah domain)
read -p "Masukkan IP VPS Lama: " OLD_IP
read -s -p "Masukkan Password SSH Root VPS Lama: " OLD_PASS
echo
read -s -p "Masukkan Password Database Pterodactyl (lama & baru sama): " DB_PASS
echo
read -p "Masukkan Domain Pterodactyl (e.g., panel.example.com): " DOMAIN
read -p "Masukkan Email Admin Baru: " ADMIN_EMAIL
read -s -p "Masukkan Password Admin Baru: " ADMIN_PASS
echo
read -p "Masukkan IP VPS Baru (untuk firewall/internal, atau Enter untuk auto-detect): " NEW_IP
NEW_IP=${NEW_IP:-$(hostname -I | awk '{print $1}' | head -n1)}  # Auto-detect first IP
DB_NAME="pterodactyl"
DB_USER="pterodactyl"

# Direktori temp
TEMP_DIR="/tmp/pterodactyl_migrasi"
mkdir -p "$TEMP_DIR"
BACKUP_DB="$TEMP_DIR/pterodactyl_db.sql"
BACKUP_PANEL_FILES="$TEMP_DIR/pterodactyl_panel_files.tar.gz"
BACKUP_WINGS="$TEMP_DIR/pterodactyl_wings.tar.gz"
BACKUP_VOLUMES="$TEMP_DIR/pterodactyl_volumes.tar.gz"  # Volumes terpisah karena besar

echo -e "${YELLOW}Membuat backup dari VPS lama... (Ini bisa lama untuk volumes)${NC}"

# Install sshpass jika belum
if ! command -v sshpass &> /dev/null; then
    apt update && apt install -y sshpass
fi

ssh_cmd() {
    sshpass -p "$OLD_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$OLD_IP" "$1"
}

scp_cmd() {
    sshpass -p "$OLD_PASS" scp -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$OLD_IP":"$1" "$2"
}

# 1. Backup Database dari VPS lama
echo -e "${YELLOW}Backup database...${NC}"
ssh_cmd "mysqldump -u $DB_USER -p'$DB_PASS' --single-transaction --routines --triggers --quick $DB_NAME > /tmp/pterodactyl_db.sql" || {
    echo -e "${RED}Error: Gagal backup DB. Cek kredensial DB di VPS lama.${NC}"
    exit 1
}
scp_cmd "/tmp/pterodactyl_db.sql" "$BACKUP_DB" || {
    echo -e "${RED}Error: Gagal transfer DB.${NC}"
    exit 1
}
ssh_cmd "rm -f /tmp/pterodactyl_db.sql"

# 2. Backup Panel Files dari VPS lama
echo -e "${YELLOW}Backup panel files...${NC}"
ssh_cmd "
    tar -czf /tmp/pterodactyl_panel_files.tar.gz \
        --exclude='/var/www/pterodactyl/storage/logs/*' \
        --exclude='/var/www/pterodactyl/bootstrap/cache/*' \
        /var/www/pterodactyl \
        /etc/nginx/sites-available/pterodactyl \
        /etc/nginx/sites-enabled/pterodactyl \
        /etc/php/8.1/fpm/pool.d/pterodactyl.conf \
        /etc/pterodactyl/config.yml \
        2>/dev/null || true
"
scp_cmd "/tmp/pterodactyl_panel_files.tar.gz" "$BACKUP_PANEL_FILES" || {
    echo -e "${RED}Error: Gagal transfer panel files.${NC}"
    exit 1
}
ssh_cmd "rm -f /tmp/pterodactyl_panel_files.tar.gz"

# 3. Backup Wings dari VPS lama (config, binary)
echo -e "${YELLOW}Backup Wings (config & binary)...${NC}"
ssh_cmd "
    tar -czf /tmp/pterodactyl_wings.tar.gz \
        /etc/pterodactyl \
        /usr/local/bin/wings \
        /etc/systemd/system/wings.service \
        2>/dev/null || true
"
scp_cmd "/tmp/pterodactyl_wings.tar.gz" "$BACKUP_WINGS" || {
    echo -e "${RED}Error: Gagal transfer Wings.${NC}"
    exit 1
}
ssh_cmd "rm -f /tmp/pterodactyl_wings.tar.gz"

# 4. Backup Volumes dari VPS lama (data server - besar!)
echo -e "${YELLOW}Backup volumes (/var/lib/pterodactyl/volumes)... Ini bisa lama!${NC}"
ssh_cmd "
    tar -czf /tmp/pterodactyl_volumes.tar.gz \
        --exclude='*.log' \
        /var/lib/pterodactyl/volumes \
        2>/dev/null || true
"
scp_cmd "/tmp/pterodactyl_volumes.tar.gz" "$BACKUP_VOLUMES" || {
    echo -e "${RED}Error: Gagal transfer volumes. Coba rsync manual jika terlalu besar (rsync -avz root@$OLD_IP:/var/lib/pterodactyl/volumes/ /var/lib/pterodactyl/volumes/).${NC}"
    exit 1
}
ssh_cmd "rm -f /tmp/pterodactyl_volumes.tar.gz"

echo -e "${GREEN}Semua backup selesai. Install di VPS baru...${NC}"

# 5. Install Dependencies Lengkap di VPS baru (Panel + Wings)
echo -e "${YELLOW}Install dependencies...${NC}"
apt update -y && apt upgrade -y
apt install -y software-properties-common curl unzip socat tar pv nginx-full mariadb-server \
    php8.1 php8.1-cli php8.1-fpm php8.1-mysql php8.1-zip php8.1-gd php8.1-mbstring php8.1-curl \
    php8.1-xml php8.1-bcmath php8.1-redis php8.1-bz2 php8.1-intl redis-server supervisor \
    sshpass ufw ca-certificates gnupg

# Enable UFW firewall (allow SSH, HTTP, HTTPS, Wings ports)
ufw --force enable
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 2022/tcp  # Wings default
ufw allow 8080/tcp  # Wings API jika perlu
ufw --force reload

# Start & enable services dasar
systemctl start mariadb redis-server
systemctl enable mariadb redis-server nginx php8.1-fpm

# 6. Setup & Secure MariaDB di VPS baru
echo -e "${YELLOW}Setup MariaDB...${NC}"
mysql -u root -e "DELETE FROM mysql.user WHERE User=''; FLUSH PRIVILEGES;"
mysql -u root -e "CREATE USER IF NOT EXISTS 'root'@'localhost' IDENTIFIED BY '$DB_PASS'; GRANT ALL ON *.* TO 'root'@'localhost' WITH GRANT OPTION; FLUSH PRIVILEGES;"
mysql -u root -p"$DB_PASS" -e "
    CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
    GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
    FLUSH PRIVILEGES;
"

# Secure installation (non-interaktif)
mysql -u root -p"$DB_PASS" -e "
    DELETE FROM mysql.user WHERE User='' OR User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
    DROP DATABASE IF EXISTS test;
    DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
    FLUSH PRIVILEGES;
"

# Restore Database
mysql -u $DB_USER -p"$DB_PASS" $DB_NAME < "$BACKUP_DB" || {
    echo -e "${YELLOW}Warning: Restore DB gagal parsial; coba manual.${NC}"
}

# 7. Install Pterodactyl Panel
echo -e "${YELLOW}Install Pterodactyl Panel...${NC}"
cd /var/www
rm -rf pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzf panel.tar.gz
chmod -R 755 /var/www/pterodactyl/storage /var/www/pterodactyl/bootstrap/cache
chown -R www-data:www-data /var/www/pterodactyl

# Install Composer jika belum
if ! command -v composer &> /dev/null; then
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
fi

cd /var/www/pterodactyl
composer install --no-dev --optimize-autoloader --no-interaction

# Setup .env (otomatis, gunakan domain)
cp .env.example .env
php artisan key:generate --force
sed -i "s/APP_URL=.*/APP_URL=http:\/\/$DOMAIN/" .env
sed -i "s/DB_HOST=.*/DB_HOST=127.0.0.1/" .env
sed -i "s/DB_PORT=.*/DB_PORT=3306/" .env
sed -i "s/DB_DATABASE=.*/DB_DATABASE=$DB_NAME/" .env
sed -i "s/DB_USERNAME=.*/DB_USERNAME=$DB_USER/" .env
sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=$DB_PASS/" .env
sed -i "s/CACHE_DRIVER=.*/CACHE_DRIVER=redis/" .env
sed -i "s/SESSION_DRIVER=.*/SESSION_DRIVER=redis/" .env
sed -i "s/QUEUE_CONNECTION=.*/QUEUE_CONNECTION=redis/" .env
sed -i "s/REDIS_HOST=.*/REDIS_HOST=127.0.0.1/" .env
sed -i "s/REDIS_PASSWORD=.*/REDIS_PASSWORD=null/" .env
sed -i "s/REDIS_PORT=.*/REDIS_PORT=6379/" .env

# Cache config
php artisan config:cache
php artisan view:cache

# Migrate & Seed (force non-interaktif)
php artisan migrate --seed --force

# Buat Admin User Otomatis
php artisan p:user:make --email "$ADMIN_EMAIL" --name "Admin" --password "$ADMIN_PASS" --admin 1 --no-interaction

# 8. Restore Panel Files dari Backup
echo -e "${YELLOW}Restore panel files...${NC}"
tar -xzf "$BACKUP_PANEL_FILES" -C / --strip-components=0 2>/dev/null || {
    echo -e "${YELLOW}Warning: Beberapa panel files gagal restore; gunakan default.${NC}"
}

# Fix permissions
chown -R www-data:www-data /var/www/pterodactyl /var/lib/pterodactyl
chmod -R 755 /var/www/pterodactyl/storage /var/www/pterodactyl/bootstrap/cache /var/lib/pterodactyl/volumes

# 9. Konfigurasi Nginx (gunakan backup jika ada, atau default dengan domain)
if [ -f /etc/nginx/sites-available/pterodactyl ]; then
    ln -sf /etc/nginx/sites-available/pterodactyl /etc/nginx/sites-enabled/ 2>/dev/null || true
    # Update server_name ke domain jika backup pakai IP lama
    sed -i "s/server_name .*/server_name $DOMAIN;/" /etc/nginx/sites-available/pterodactyl
else
    # Generate basic nginx config dengan domain
    cat > /etc/nginx/sites-available/pterodactyl <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    root /var/www/pterodactyl/public;
    index index.php;
    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ \.php$ {
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/pterodactyl /etc/nginx/sites-enabled/
fi

# Test & restart Nginx
nginx -t && systemctl restart nginx || {
    echo -e "${RED}Error: Nginx config invalid. Cek /etc/nginx/sites-available/pterodactyl${NC}"
    exit 1
}

# PHP-FPM Pool (jika backup gagal, buat default)
if [ ! -f /etc/php/8.1/fpm/pool.d/pterodactyl.conf ]; then
    cat > /etc/php/8.1/fpm/pool.d/pterodactyl.conf <<EOF
[pterodactyl]
user = www-data
group = www-data
listen = /run/php/php8.1-fpm-pterodactyl.sock
listen.owner = www-data
listen.group = www-data
php_admin_value[disable_functions] = exec,passthru,shell_exec,system
php_admin_flag[allow_url_fopen] = on
pm = dynamic
pm.max_children = 75
pm.start_servers = 10
pm.min_spare_servers = 5
pm.max_spare_servers = 20
pm.max_requests = 500
EOF
fi
systemctl restart php8.1-fpm

# 10. Queue & Scheduler (Supervisor & Cron) untuk Panel
echo -e "${YELLOW}Setup Queue & Scheduler Panel...${NC}"

# Supervisor config untuk queue
cat > /etc/supervisor/conf.d/pterodactyl.conf <<EOF
[program:pterodactyl-queue-worker-00]
process_name=%(program_name)s_%(process_num)02d
command=php /var/www/pterodactyl/artisan queue:work --sleep=3 --tries=3 --max-time=3600
autostart=true
autorestart=true
user=www-data
numprocs=1
redirect_stderr=true
stdout_logfile=/var/www/pterodactyl/storage/logs/queue-worker.log
stopwaitsecs=3600

[program:pterodactyl-scheduler]
process_name=%(program_name)s
command=php /var/www/pterodactyl/artisan schedule:work
autostart=true
autorestart=true
user=www-data
redirect_stderr=true
stdout_logfile=/var/www/pterodactyl/storage/logs/scheduler.log
EOF
supervisorctl reread
supervisorctl update
supervisorctl start pterodactyl-queue-worker-00 pterodactyl-scheduler || true

# Restart queue
php /var/www/pterodactyl/artisan queue:restart

# Cron job untuk scheduler
(crontab -l 2>/dev/null; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | crontab -

# 11. Install & Restore Wings di VPS baru
echo -e "${YELLOW}Install & Restore Wings...${NC}"

# Buat direktori Wings jika belum
mkdir -p /etc/pterodactyl /var/lib/pterodactyl/volumes

# Install Wings binary (jika backup gagal, download fresh)
if [ -f "$BACKUP_WINGS" ] && tar -tzf "$BACKUP_WINGS" | grep -q "/usr/local/bin/wings"; then
    tar -xzf "$BACKUP_WINGS" -C / --strip-components=0 2>/dev/null || {
        echo -e "${YELLOW}Backup Wings gagal; install fresh.${NC}"
        curl -L -o /tmp/wings.tar.gz https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64.tar.gz
        tar -xzf /tmp/wings.tar.gz -C /usr/local/bin wings
        chmod u+x /usr/local/bin/wings
        rm /tmp/wings.tar.gz
    }
else
    echo -e "${YELLOW}No Wings backup atau invalid; install fresh.${NC}"
    curl -L -o /tmp/wings.tar.gz https://github.com/pterodactyl
