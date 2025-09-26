#!/bin/bash

# ========================================
# 🚀 Manual Installer Pterodactyl (Admin auto)
# by RissXD (mod)
# ========================================

set -euo pipefail

echo "==================================="
echo "🚀 Installer Pterodactyl Panel + Wings (Admin auto)"
echo "==================================="

read -p "🌐 Masukkan Domain Panel (contoh: panel.example.com): " DOMAIN_PANEL
read -p "🌐 Masukkan Domain Node (contoh: node.example.com): " DOMAIN_NODE
read -p "💾 Masukkan RAM Node (MB) [default 8192]: " RAM_NODE_INPUT
read -p "💽 Masukkan Disk Node (MB) [default 100000]: " DISK_NODE_INPUT

# Set defaults jika kosong
RAM_NODE=${RAM_NODE_INPUT:-8192}
DISK_NODE=${DISK_NODE_INPUT:-100000}
TIMEZONE="Asia/Jakarta"

# Admin otomatis
ADMIN_USER="admin"
ADMIN_PASS="admin1"
ADMIN_EMAIL="admin@${DOMAIN_PANEL}"

echo ""
echo "==================================="
echo "📝 Konfigurasi yang akan dipakai:"
echo "Panel Domain : $DOMAIN_PANEL"
echo "Node Domain  : $DOMAIN_NODE"
echo "Admin Email  : $ADMIN_EMAIL  (otomatis)"
echo "Admin User   : $ADMIN_USER     (otomatis)"
echo "Admin Pass   : $ADMIN_PASS     (otomatis)"
echo "RAM Node     : ${RAM_NODE} MB"
echo "Disk Node    : ${DISK_NODE} MB"
echo "Timezone     : $TIMEZONE"
echo "==================================="
sleep 2

echo "🔄 Update & upgrade sistem (ini butuh waktu)..."
apt update -y && apt upgrade -y

echo "📥 Menjalankan installer Pterodactyl panel..."
# Menjalankan installer interaktif tapi semua jawaban otomatis lewat here-doc
bash <(curl -s https://pterodactyl-installer.se) <<EOF
0
y

$ADMIN_USER
$ADMIN_PASS
$TIMEZONE
$ADMIN_EMAIL
$ADMIN_USER
$ADMIN_USER
$ADMIN_PASS
$DOMAIN_PANEL
y
y
1
y
y
y
y
y
A
EOF

echo "✅ Panel Pterodactyl terinstal: https://$DOMAIN_PANEL"
echo "   Username: $ADMIN_USER"
echo "   Password: $ADMIN_PASS"
echo ""

echo "📥 Menjalankan installer Wings/Node..."
bash <(curl -s https://raw.githubusercontent.com/SkyzoOffc/Pterodactyl-Theme-Autoinstaller/main/createnode.sh) <<EOF
Singapore
Node By RissXD
$DOMAIN_NODE
Node By RissXD
$RAM_NODE
$DISK_NODE
1
EOF

echo ""
echo "✅ Wings/Node selesai diinstall pada: $DOMAIN_NODE"
echo "⚡ Silakan login ke panel dan buat allocation lalu ambil token Wings untuk node."
echo ""
echo "📦 Untuk restart wings: systemctl restart wings"
echo "🔐 Untuk keamanan: pastikan DNS A record keduanya mengarah ke VPS, dan port firewall terbuka sesuai kebutuhan."
