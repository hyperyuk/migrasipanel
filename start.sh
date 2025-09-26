#!/usr/bin/env expect

set timeout -1

# === Input manual dari user ===
send_user "🌐 Masukkan Domain Panel (contoh: panel.example.com): "
expect_user -re "(.*)\n"
set DOMAIN_PANEL $expect_out(1,string)

send_user "🌐 Masukkan Domain Node (contoh: node.example.com): "
expect_user -re "(.*)\n"
set DOMAIN_NODE $expect_out(1,string)

send_user "💾 Masukkan RAM Node (MB) [default 8192]: "
expect_user -re "(.*)\n"
set RAM_NODE $expect_out(1,string)
if { $RAM_NODE eq "" } { set RAM_NODE 8192 }

send_user "💽 Masukkan Disk Node (MB) [default 100000]: "
expect_user -re "(.*)\n"
set DISK_NODE $expect_out(1,string)
if { $DISK_NODE eq "" } { set DISK_NODE 100000 }

# === Admin otomatis ===
set ADMIN_USER "admin"
set ADMIN_PASS "admin1"
set ADMIN_EMAIL "admin@${DOMAIN_PANEL}"

send_user "\n===================================\n"
send_user "🚀 Mulai Install dengan data berikut:\n"
send_user "Panel Domain : $DOMAIN_PANEL\n"
send_user "Node Domain  : $DOMAIN_NODE\n"
send_user "Admin Email  : $ADMIN_EMAIL\n"
send_user "Admin User   : $ADMIN_USER\n"
send_user "Admin Pass   : $ADMIN_PASS\n"
send_user "RAM Node     : $RAM_NODE MB\n"
send_user "Disk Node    : $DISK_NODE MB\n"
send_user "===================================\n\n"

# === Jalankan installer panel ===
spawn bash -c "curl -s https://pterodactyl-installer.se | bash"
expect {
    "Input 0-6" { send "0\r"; exp_continue }
    "(y/N)" { send "y\r"; exp_continue }
    "Database name" { send "\r"; exp_continue }
    "Database username" { send "$ADMIN_USER\r"; exp_continue }
    "Password (press enter" { send "$ADMIN_PASS\r"; exp_continue }
    "timezone" { send "Asia/Jakarta\r"; exp_continue }
    "email address" { send "$ADMIN_EMAIL\r"; exp_continue }
    "Username for the initial" { send "$ADMIN_USER\r"; exp_continue }
    "First name" { send "Admin\r"; exp_continue }
    "Last name" { send "Panel\r"; exp_continue }
    "Password for the initial" { send "$ADMIN_PASS\r"; exp_continue }
    "FQDN of this panel" { send "$DOMAIN_PANEL\r"; exp_continue }
    "configure UFW" { send "y\r"; exp_continue }
    "configure HTTPS" { send "y\r"; exp_continue }
    "appropriate number" { send "1\r"; exp_continue }
    "I agree that this HTTPS" { send "y\r"; exp_continue }
    "Proceed anyways" { send "y\r"; exp_continue }
    "(yes/no)" { send "y\r"; exp_continue }
    "Continue with installation?" { send "y\r"; exp_continue }
    "Still assume SSL?" { send "y\r"; exp_continue }
    "Terms of Service" { send "y\r"; exp_continue }
    "(A)gree/(C)ancel" { send "A\r"; exp_continue }
    eof
}

# === Install Wings ===
spawn bash -c "curl -s https://raw.githubusercontent.com/SkyzoOffc/Pterodactyl-Theme-Autoinstaller/main/createnode.sh | bash"
expect {
    "Masukkan nama lokasi" { send "Singapore\r"; exp_continue }
    "deskripsi lokasi" { send "Node By RissXD\r"; exp_continue }
    "Masukkan domain" { send "$DOMAIN_NODE\r"; exp_continue }
    "nama node" { send "Node By RissXD\r"; exp_continue }
    "RAM" { send "$RAM_NODE\r"; exp_continue }
    "disk space" { send "$DISK_NODE\r"; exp_continue }
    "Locid" { send "1\r"; exp_continue }
    eof
}

send_user "\n✅ Install selesai!\n"
send_user "🌐 Panel: https://$DOMAIN_PANEL\n"
send_user "👤 User : $ADMIN_USER\n"
send_user "🔐 Pass : $ADMIN_PASS\n"
