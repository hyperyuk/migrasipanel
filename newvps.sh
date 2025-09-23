#!/bin/bash
# ==========================================
# Script Reset VPS ke kondisi Kosongan
# By Ryunitro
# ==========================================

echo "======================================="
echo "   WARNING!!! VPS AKAN DIRESET TOTAL   "
echo " Semua data, website, database, config "
echo "            akan dihapus!              "
echo "======================================="
read -p "Ketik 'YA' untuk lanjut: " confirm

if [[ "$confirm" != "YA" ]]; then
    echo "Dibatalkan."
    exit 1
fi

# Update dulu
apt update -y

echo "[*] Menghapus layanan umum (nginx, mysql, docker, wings, pterodactyl, dll)..."
apt purge -y nginx* mysql* mariadb* php* apache2* docker* nodejs* redis* certbot* ufw
apt autoremove -y
apt clean

echo "[*] Menghapus file web & konfigurasi..."
rm -rf /var/www/*
rm -rf /etc/nginx/*
rm -rf /etc/mysql/*
rm -rf /etc/pterodactyl
rm -rf /var/lib/pterodactyl
rm -rf /root/migrasi
rm -rf /etc/letsencrypt

echo "[*] Reset firewall..."
ufw disable >/dev/null 2>&1
iptables -F
iptables -X

echo "[*] Membersihkan log..."
rm -rf /var/log/*

echo "[*] Membersihkan cache apt..."
rm -rf /var/lib/apt/lists/*
apt update -y

echo "======================================="
echo " VPS sudah kosong (semi fresh install)."
echo " Saran: reboot VPS untuk hasil maksimal."
echo "======================================="
