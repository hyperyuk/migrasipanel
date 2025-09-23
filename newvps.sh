#!/bin/bash
# VPS Wipe Script (Ubuntu/Debian)
# Gunakan dengan hati-hati!

echo "=== VPS CLEANER - Semua data akan hilang! ==="
read -p "Apakah kamu yakin ingin melanjutkan? (y/N): " confirm
if [[ "$confirm" != "y" ]]; then
  echo "Dibatalkan."
  exit 1
fi

echo "[1/6] Hapus web server & database..."
apt-get purge -y nginx* apache2* mysql* mariadb* postgresql* php* nodejs* docker* redis* mongodb* vsftpd* proftpd*

echo "[2/6] Hapus direktori web & config..."
rm -rf /var/www/* /etc/nginx /etc/apache2 /etc/mysql /etc/postgresql /etc/php /etc/letsencrypt

echo "[3/6] Hapus user non-root..."
for user in $(awk -F: '$3 >= 1000 {print $1}' /etc/passwd); do
    if [[ "$user" != "root" ]]; then
        userdel -r "$user"
    fi
done

echo "[4/6] Bersihkan paket & cache..."
apt-get autoremove -y
apt-get autoclean -y
apt-get clean

echo "[5/6] Bersihkan log..."
find /var/log -type f -delete

echo "[6/6] Reset motd & banner..."
echo "Welcome to a clean VPS" > /etc/motd

echo "=== VPS sudah dikosongkan. Tapi OS tetap ada. ==="
echo "Kalau mau benar-benar fresh 100%, lakukan reinstall OS dari panel provider."
