#!/bin/bash

# Fungsi konfirmasi
confirm() {
    while true; do
        read -p "$1 (y/N): " choice
        case "$choice" in
            y|Y ) return 0;;
            n|N ) return 1;;
            * ) echo "Pilihan salah. Ketik y untuk ya, n untuk tidak.";;
        esac
    done
}

# Fungsi error handling
error_exit() {
    echo "Error: $1" >&2
    exit 1
}

echo "=== SCRIPT RESET VPS KE KONDISI BARU (SEPERTI FRESH DIGITALOCEAN) ==="
echo "INI AKAN MENGHAPUS SEMUA DATA, USERS, SERVICES, DAN CONFIGS!"
echo "Backup dulu jika ada data penting. Hanya untuk Ubuntu/Debian."
echo "Jalankan sebagai root."

if confirm "Lanjutkan reset VPS? (Data hilang permanen!)"; then
    echo "OK, mulai reset..."
else
    echo "Dibatalkan. Bye!"
    exit 0
fi

DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/root/pre_reset_backup_$DATE"  # Backup minimal untuk logs/history
mkdir -p "$BACKUP_DIR"

# 1. Backup minimal (history, logs) - opsional
echo "Backup minimal (history & logs) ke $BACKUP_DIR..."
history > "$BACKUP_DIR/history.txt" 2>/dev/null
cp /var/log/* "$BACKUP_DIR/" 2>/dev/null || echo "Warning: Gagal backup logs"
echo "Backup minimal selesai. Hapus manual setelah reset jika tidak perlu."

# 2. Stop & Disable Non-Essential Services
echo "Stop & disable services..."
services_to_stop=("nginx" "apache2" "mysql" "mariadb" "postgresql" "docker" "wings" "pterodactyl" "php*-fpm" "redis" "memcached" "fail2ban" "ufw")
for service in "${services_to_stop[@]}"; do
    systemctl stop $service 2>/dev/null
    systemctl disable $service 2>/dev/null
    echo "Stopped/disabled: $service"
done

# 3. Hapus Users (kecuali root)
echo "Hapus users non-root..."
users=$(awk -F: '$3>=1000 && $1!="nobody" {print $1}' /etc/passwd)
for user in $users; do
    if [ "$user" != "root" ]; then
        userdel -r $user 2>/dev/null || echo "Warning: Gagal hapus user $user"
    fi
done
rm -rf /home/* /root/.ssh /root/.bash_history 2>/dev/null

# 4. Hapus Files & Directories
echo "Hapus files & directories..."
rm -rf /var/www/* /var/lib/mysql/* /var/lib/docker/* /var/lib/pterodactyl/* /etc/pterodactyl/* /etc/nginx/sites-enabled/* /etc/apache2/sites-enabled/* /opt/* /tmp/* /var/tmp/* /var/log/* 2>/dev/null
rm -rf /etc/letsencrypt /etc/ssl/private /root/.composer /root/.npm /root/.cargo 2>/dev/null
echo "Files dihapus (web, DB, Docker, Pterodactyl, SSL, etc.)."

# 5. Clean Packages
echo "Clean packages..."
apt update
apt autoremove -y --purge
apt autoclean
apt remove --purge $(dpkg -l | grep '^ii' | awk '{print $2}' | grep -v -E "(linux|ubuntu|debian|base|core|essential)") -y 2>/dev/null || echo "Warning: Beberapa packages gagal remove"
apt install -y ubuntu-minimal  # Pastikan minimal install
apt upgrade -y
echo "Packages dibersihkan & di-upgrade."

# 6. Reset Network Config (untuk DHCP seperti DO)
echo "Reset network config ke DHCP..."
if [ -d "/etc/netplan" ]; then
    # Ubuntu 18+ (Netplan)
    cat > /etc/netplan/01-netcfg.yaml << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    enp0s3:  # Ganti ke interface Anda (cek: ip link)
      dhcp4: true
    ens3:    # Atau ens3 (umum di DO)
      dhcp4: true
EOF
    netplan apply || echo "Warning: Gagal apply netplan. Cek interface dengan 'ip link'."
elif [ -f "/etc/network/interfaces" ]; then
    # Debian/Ubuntu lama
    sed -i 's/iface eth0 inet static/iface eth0 inet dhcp/' /etc/network/interfaces 2>/dev/null
    ifup eth0 2>/dev/null || echo "Warning: Gagal restart network."
fi

# 7. Clear Logs & History
echo "Clear logs & history..."
> /var/log/auth.log
> /var/log/syslog
> /var/log/kern.log
history -c
rm -f /root/.bash_history

# 8. Setup Basic Security
echo "Setup security dasar..."
read -s -p "Masukkan password root baru: " NEW_ROOT_PASS
echo -e "$NEW_ROOT_PASS\n$NEW_ROOT_PASS" | passwd root 2>/dev/null || echo "Warning: Gagal update root pass."

# Disable root SSH login
sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config 2>/dev/null
sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config 2>/dev/null

# Buat user baru (opsional, seperti DO default)
if confirm "Buat user baru (misal 'ubuntu') dengan sudo & SSH key?"; then
    read -p "Username baru: " NEW_USER
    useradd -m -s /bin/bash $NEW_USER
    usermod -aG sudo $NEW_USER
    echo -e "$NEW_ROOT_PASS\n$NEW_ROOT_PASS" | passwd $NEW_USER 2>/dev/null
    mkdir -p /home/$NEW_USER/.ssh
    chmod 700 /home/$NEW_USER/.ssh
    echo "User  $NEW_USER dibuat. Setup SSH key manual: ssh-copy-id $NEW_USER@IP_VPS"
fi

# Enable UFW Firewall (basic)
apt install -y ufw 2>/dev/null
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw --force enable
echo "UFW enabled: SSH allowed, others denied."

# 9. Reboot
if confirm "Reboot VPS sekarang? (VPS akan restart seperti baru)"; then
    echo "Reboot dalam 10 detik... Backup minimal ada di $BACKUP_DIR"
    sleep 10
    reboot
else
    echo "Reboot dibatalkan. Jalankan 'reboot' manual setelah verifikasi."
    echo "VPS sudah reset (kecuali reboot). Hapus $BACKUP_DIR jika tidak perlu."
fi
