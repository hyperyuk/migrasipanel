#!/usr/bin/env bash
# migrate-pterodactyl.sh
# Migrasi Pterodactyl Panel / Wings dari VPS lama -> VPS baru (interaktif)
# Jalankan di VPS baru sebagai root
set -euo pipefail
IFS=$'\n\t'

############################
# Helper
############################
die(){ echo "ERROR: $*" >&2; exit 1; }
ok(){ echo -e "\e[32m[OK]\e[0m $*"; }
info(){ echo -e "\e[34m[INFO]\e[0m $*"; }
warn(){ echo -e "\e[33m[WARN]\e[0m $*"; }

confirm() {
  read -rp "$1 [y/N]: " ans
  case "$ans" in
    [yY][eE][sS]|[yY]) return 0;;
    *) return 1;;
  esac
}

require_root() {
  if [ "$EUID" -ne 0 ]; then
    die "Script must be run as root. Use sudo or run as root."
  fi
}

check_cmds() {
  local miss=()
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      miss+=("$c")
    fi
  done
  if [ ${#miss[@]} -ne 0 ]; then
    echo "Installing missing packages: ${miss[*]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${miss[@]}"
  fi
}

############################
# Main
############################
require_root

echo "=== MIGRATE PTERODACTYL ==="
info "Pastikan VPS lama mengizinkan koneksi SSH dengan password (atau siapkan key)."
read -rp "Masukkan IP VPS lama: " OLD_IP
read -rsp "Masukkan password root VPS lama: " OLD_PASS
echo
echo
echo "Pilih yang mau dimigrasi:"
echo "1) panel (Pterodactyl Panel)"
echo "2) wings (Pterodactyl Wings)"
read -rp "Pilihan (1/2): " TYPE

if [[ "$TYPE" == "1" || "$TYPE" =~ ^[Pp]anel$ ]]; then
  MODE="panel"
elif [[ "$TYPE" == "2" || "$TYPE" =~ ^[Ww]ings$ ]]; then
  MODE="wings"
else
  die "Pilihan tidak valid."
fi

read -rp "Masukkan domain baru/panel (contoh: panel.example.com) (biarkan kosong jika tidak pakai domain): " NEW_DOMAIN

# optional DB creds from old server
info "Opsional: masukkan kredensial DB MySQL/MariaDB di VPS lama (jika diketahui)."
read -rp "Nama DB panel (default: panel): " OLD_DB_NAME
OLD_DB_NAME=${OLD_DB_NAME:-panel}
read -rp "User DB (default: root): " OLD_DB_USER
OLD_DB_USER=${OLD_DB_USER:-root}
read -sp "Password DB lama (biarkan kosong jika tidak tahu): " OLD_DB_PASS
echo

# install helpers locally
info "Memastikan paket dasar ada (curl, wget, rsync, sshpass, unzip, git)..."
check_cmds curl wget rsync sshpass unzip git

# create temp dir
WORKDIR="/root/migrate_pterodactyl_$(date +%s)"
mkdir -p "$WORKDIR"
info "Working dir: $WORKDIR"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

run_ssh_old() {
  sshpass -p "$OLD_PASS" ssh $SSH_OPTS root@"$OLD_IP" -- "$@"
}

scp_from_old() {
  local remote_path=$1
  local local_dest=$2
  sshpass -p "$OLD_PASS" scp $SSH_OPTS -r "root@${OLD_IP}:${remote_path}" "${local_dest}"
}

rsync_from_old() {
  local remote_path=$1
  local local_dest=$2
  RSYNC_RSH="sshpass -p ${OLD_PASS} ssh $SSH_OPTS" rsync -az --progress -e "$RSYNC_RSH" "root@${OLD_IP}:${remote_path}" "${local_dest}"
}

############################
# Begin mode-specific steps
############################
if [ "$MODE" = "panel" ]; then
  info "Migrasi PANEL dimulai..."
  # 1) Stop panel services on new VPS if any (not destructive)
  systemctl stop pteroq.service 2>/dev/null || true
  systemctl stop pterodactyl-worker.service 2>/dev/null || true
  systemctl stop nginx 2>/dev/null || true
  systemctl stop mariadb 2>/dev/null || true

  # 2) Copy /var/www/pterodactyl and .env file plus storage
  info "Menyalin folder /var/www/pterodactyl dari VPS lama..."
  mkdir -p "$WORKDIR/panel"
  # best-effort rsync
  if rsync_from_old "/var/www/pterodactyl" "$WORKDIR/panel/"; then
    ok "Sukses menyalin /var/www/pterodactyl"
  else
    warn "Gagal rsync /var/www/pterodactyl. Mencoba scp..."
    scp_from_old "/var/www/pterodactyl" "$WORKDIR/panel/" || die "Gagal menyalin folder panel."
  fi

  # 3) Copy nginx config & ssl (if ada)
  warn "Mencoba menyalin konfigurasi nginx dari /etc/nginx/sites-available dan /etc/letsencrypt (jika ada)."
  mkdir -p "$WORKDIR/nginx"
  rsync_from_old "/etc/nginx/sites-available" "$WORKDIR/nginx/" || true
  rsync_from_old "/etc/letsencrypt" "$WORKDIR/nginx/" || true

  # 4) Database dump
  if [ -n "$OLD_DB_PASS" ]; then
    info "Melakukan mysqldump database '$OLD_DB_NAME' dari VPS lama..."
    # Try streaming mysqldump (prompting for mysql client on old server)
    # Use careful quoting
    run_ssh_old "mysqldump --single-transaction --quick --lock-tables=false -u${OLD_DB_USER} -p'${OLD_DB_PASS}' ${OLD_DB_NAME} > /tmp/${OLD_DB_NAME}_dump.sql" || warn "mysqldump mungkin gagal. Cek kredensial atau ketersediaan mysqldump di VPS lama."
    rsync_from_old "/tmp/${OLD_DB_NAME}_dump.sql" "$WORKDIR/" || true
    run_ssh_old "rm -f /tmp/${OLD_DB_NAME}_dump.sql" || true
    if [ -f "$WORKDIR/${OLD_DB_NAME}_dump.sql" ]; then
      ok "Dump database berhasil disalin ke $WORKDIR/${OLD_DB_NAME}_dump.sql"
    else
      warn "File dump tidak ditemukan di $WORKDIR. Lanjutkan tanpa import."
    fi
  else
    warn "Kredensial DB lama tidak diberikan. Script akan mencoba menyalin /var/lib/mysql (risiko kompatibilitas)."
    if confirm "Coba salin seluruh /var/lib/mysql dari VPS lama ke VPS baru? (Hanya lakukan jika versi MySQL/MariaDB sama)"; then
      mkdir -p "$WORKDIR/mysql"
      rsync_from_old "/var/lib/mysql" "$WORKDIR/mysql/" || warn "Gagal rsync /var/lib/mysql"
    else
      warn "Lewati penyalinan /var/lib/mysql. Anda harus mengekspor DB manual."
    fi
  fi

  # 5) Install dependencies on new VPS (PHP, nginx, mariadb, composer, redis)
  info "Menginstall dependency dasar di VPS baru (PHP, nginx, mariadb, redis, unzip, composer)..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common curl git unzip wget \
    nginx php php-fpm php-mysql php-redis php-mbstring php-xml php-cli php-curl php-zip mariadb-server redis-server \
    certbot python3-certbot-nginx composer

  ok "Dependency terinstall (pastikan versi PHP sesuai kebutuhan Pterodactyl)."

  # 6) Restore files to proper locations
  info "Memindahkan file panel ke /var/www/pterodactyl (backup jika ada)..."
  if [ -d /var/www/pterodactyl ]; then
    mv /var/www/pterodactyl "/var/www/pterodactyl.bak.$(date +%s)"
    warn "Backup folder lama disimpan."
  fi
  mkdir -p /var/www
  rsync -a "$WORKDIR/panel/pterodactyl/" /var/www/pterodactyl/ || die "Gagal copy panel ke /var/www/pterodactyl"

  chown -R www-data:www-data /var/www/pterodactyl
  chmod -R 755 /var/www/pterodactyl

  # 7) Place .env (if exists)
  if [ -f "$WORKDIR/panel/pterodactyl/.env" ]; then
    cp "$WORKDIR/panel/pterodactyl/.env" /var/www/pterodactyl/.env
    ok ".env disalin."
  else
    warn ".env tidak ditemukan. Anda harus menyiapkan file .env manual."
  fi

  # 8) Import database if dump exists
  if [ -f "$WORKDIR/${OLD_DB_NAME}_dump.sql" ]; then
    info "Mengimpor database ke MariaDB lokal..."
    # Create DB & user from .env if present, else ask for new DB user/pass
    # parse .env for DB credentials if present
    if [ -f /var/www/pterodactyl/.env ]; then
      ENV_DB_NAME=$(grep -E '^DB_DATABASE=' /var/www/pterodactyl/.env | cut -d'=' -f2-)
      ENV_DB_USER=$(grep -E '^DB_USERNAME=' /var/www/pterodactyl/.env | cut -d'=' -f2-)
      ENV_DB_PASS=$(grep -E '^DB_PASSWORD=' /var/www/pterodactyl/.env | cut -d'=' -f2-)
    else
      ENV_DB_NAME=""
      ENV_DB_USER=""
      ENV_DB_PASS=""
    fi

    if [ -z "$ENV_DB_NAME" ]; then
      read -rp "Masukkan nama DB baru di VPS baru (default: panel): " NEW_DB_NAME
      NEW_DB_NAME=${NEW_DB_NAME:-panel}
      read -rp "Masukkan user DB baru (default: ptero): " NEW_DB_USER
      NEW_DB_USER=${NEW_DB_USER:-ptero}
      read -sp "Masukkan password untuk user DB baru: " NEW_DB_PASS
      echo
    else
      NEW_DB_NAME="$ENV_DB_NAME"
      NEW_DB_USER="$ENV_DB_USER"
      NEW_DB_PASS="$ENV_DB_PASS"
      info "Menggunakan kredensial DB dari .env: DB=$NEW_DB_NAME USER=$NEW_DB_USER"
    fi

    # create db and user
    mysql -e "CREATE DATABASE IF NOT EXISTS \`${NEW_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    mysql -e "CREATE USER IF NOT EXISTS '${NEW_DB_USER}'@'localhost' IDENTIFIED BY '${NEW_DB_PASS}';"
    mysql -e "GRANT ALL PRIVILEGES ON \`${NEW_DB_NAME}\`.* TO '${NEW_DB_USER}'@'localhost'; FLUSH PRIVILEGES;"
    ok "Database & user dibuat."

    # import
    mysql "$NEW_DB_NAME" < "$WORKDIR/${OLD_DB_NAME}_dump.sql" || warn "Import SQL gagal (cek versi MySQL/MariaDB)."
    ok "Import SQL selesai (atau ada peringatan)."
  else
    warn "Tidak ada dump SQL untuk diimport."
  fi

  # 9) Set up nginx site if NEW_DOMAIN diberikan and copy certs if available
  if [ -n "$NEW_DOMAIN" ]; then
    info "Mempersiapkan nginx site untuk $NEW_DOMAIN"
    cat >/etc/nginx/sites-available/pterodactyl <<EOF
server {
    listen 80;
    server_name ${NEW_DOMAIN};
    root /var/www/pterodactyl/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.access.log;
    error_log /var/log/nginx/pterodactyl.error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/pterodactyl /etc/nginx/sites-enabled/pterodactyl
    nginx -t && systemctl reload nginx || warn "Nginx reload gagal."
    info "Menyiapkan certbot (Let's Encrypt) untuk $NEW_DOMAIN"
    if confirm "Ingin jalankan certbot untuk domain ini sekarang? (pastikan DNS menunjuk ke VPS baru)"; then
      certbot --nginx -d "$NEW_DOMAIN" --non-interactive --agree-tos -m admin@"${NEW_DOMAIN}" || warn "Certbot gagal atau butuh interaksi."
    fi
  fi

  # 10) Composer install & artisan optimize
  info "Menjalankan composer install & artisan (butuh composer dan php) di /var/www/pterodactyl"
  cd /var/www/pterodactyl || die "Folder panel tidak ada."
  if [ -f composer.json ]; then
    composer install --no-dev --optimize-autoloader || warn "composer install bermasalah."
    php artisan key:generate --force || true
    php artisan migrate --force || warn "php artisan migrate bermasalah."
    php artisan p:environment:setup || true
    php artisan p:environment:database || true
    php artisan config:cache || true
    ok "Composer & artisan selesai."
  else
    warn "composer.json tidak ditemukan; lewati langkah composer."
  fi

  # 11) Set permissions
  chown -R www-data:www-data /var/www/pterodactyl
  chmod -R 755 /var/www/pterodactyl/storage /var/www/pterodactyl/bootstrap/cache || true

  # 12) Start services
  systemctl enable --now nginx || true
  systemctl enable --now mariadb || true
  systemctl enable --now redis-server || true

  info "Panel migrated. Silakan cek /var/www/pterodactyl, nginx config, dan akses web pada domain/IP."
  ok "Selesai. Periksa log: /var/log/nginx/pterodactyl.error.log dan storage/logs di panel."

elif [ "$MODE" = "wings" ]; then
  info "Migrasi WINGS dimulai..."
  read -rp "Masukkan FQDN Wings (contoh: wings.example.com): " WINGS_FQDN
  # Stop local wings if any
  systemctl stop wings 2>/dev/null || true

  # Copy wings config & data
  info "Menyalin konfigurasi wings dari VPS lama (biasanya /etc/pterodactyl or /etc/wings) ..."
  mkdir -p "$WORKDIR/wings"
  rsync_from_old "/etc/pterodactyl" "$WORKDIR/wings/" || true
  rsync_from_old "/etc/wings" "$WORKDIR/wings/" || true
  rsync_from_old "/var/lib/pterodactyl" "$WORKDIR/wings/" || true
  rsync_from_old "/var/lib/wings" "$WORKDIR/wings/" || true

  # Install wings binary (simple method: download latest from repo) - note: may require internet
  info "Menginstall dependency docker & wings (docker diperlukan untuk node)."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

  # Install docker if not present
  if ! command -v docker >/dev/null 2>&1; then
    info "Menginstall Docker..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && sh /tmp/get-docker.sh || warn "Gagal install Docker otomatis."
  fi

  # Deploy wings binary (best-effort: download from release)
  if ! command -v wings >/dev/null 2>&1; then
    info "Mengambil binary wings (best-effort) — pastikan versi cocok dengan panel."
    mkdir -p /opt/wings
    # Attempt to download a generic wings binary (user may need to replace)
    warn "Script tidak mengunduh binary wings spesifik. Silakan install wings sesuai dokumentasi Pterodactyl atau beri tahu jika mau saya tambahkan unduh otomatis."
  fi

  # Restore config files
  if [ -d "$WORKDIR/wings" ]; then
    cp -r "$WORKDIR/wings/"* /etc/ || true
    ok "Config wings disalin ke /etc/"
  fi

  # Update systemd service for wings (if provided)
  if [ -f /etc/systemd/system/wings.service ]; then
    systemctl daemon-reload
    systemctl enable --now wings || warn "Gagal start wings service."
  else
    warn "Systemd service wings tidak ditemukan di /etc. Anda mungkin perlu membuatnya sesuai dokumentasi Pterodactyl."
  fi

  # UFW / Firewall
  info "Menyiapkan UFW dasar (ssh, http/https, wings default ports 8080/8081/... )"
  check_cmds ufw
  ufw allow OpenSSH || true
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
  # Wings default: 8080/8081 or custom; tidak menutup kemungkinan port lain diperlukan
  if confirm "Buka port default Wings 8080 (jawab y jika ingin)?"; then
    ufw allow 8080/tcp || true
  fi
  ufw --force enable || true

  ok "Selesai setup dasar Wings. Pastikan binary wings, config (wings.yml), dan Docker sudah terpasang dengan benar."
else
  die "Mode tidak dikenali."
fi

############################
# Final notes
############################
echo
info "===== Selesai proses script (best-effort). ====="
echo "Hal-hal yang perlu dicek manual:"
echo "- Versi PHP/MySQL/MariaDB pada VPS lama vs baru (kompatibilitas)."
echo "- File .env, APP_KEY, dan kredensial API di panel."
echo "- Systemd service names (pteroq, wings) dan path binary."
echo "- Konfigurasi firewall dan DNS (pastikan domain menunjuk ke IP baru)."
echo "- Jika ada galat, periksa log nginx dan storage/logs di panel."
echo
warn "Jika migrasi gagal di beberapa langkah (mis. mysqldump gagal), lakukan eksport manual di VPS lama dan salin file .sql ke $WORKDIR lalu import."
echo
ok "Working dir: $WORKDIR (jika ingin melihat file yang disalin)"
echo "Terakhir: restart services bila perlu (systemctl restart nginx mariadb redis-server)"
