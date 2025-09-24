#!/bin/bash

# Pterodactyl Migration Script (Revised)
# This script migrates Pterodactyl panel or Wings from old VPS to new VPS.
# Key Changes:
# - Added separate FQDN input for Wings (e.g., wings.example.com) since Wings nodes require a FQDN for identification in the panel.
# - Clarified ports: SSH uses port 22 (for remote access during migration). Wings API listens on port 2022 (not 22).
#   - Port 22 is ONLY for SSH; do not confuse it with Wings.
# - Panel uses domain (e.g., panel.example.com) for APP_URL.
# - Wings config updated with FQDN if provided.
# - Improved Wings config: API on 2022, SFTP bind_port set to a separate port (e.g., 2222) to avoid conflicts.
# - Assumptions remain the same; run on NEW VPS as root.
# - For Wings, after migration, you'll need to update the node in the panel with the new FQDN and token.

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root or with sudo."
    exit 1
fi

# Prompt for inputs
echo "=== Pterodactyl Migration Script (Revised) ==="
print_status "Port Clarification:"
print_status "- SSH (for this migration) uses port 22 on old VPS."
print_status "- Pterodactyl Panel: Domain (e.g., panel.example.com), ports 80/443."
print_status "- Pterodactyl Wings: FQDN (e.g., wings.example.com), API port 2022 (NOT 22)."
echo ""
print_status "Enter the following details for the old VPS:"

read -p "IP of old VPS: " OLD_IP
read -s -p "SSH password for old VPS (root or sudo user): " OLD_PW
echo  # New line after password input
read -p "New domain for panel (e.g., panel.example.com): " NEW_DOMAIN

# Menu for migration type
echo ""
echo "Choose migration type:"
echo "1) Full Panel Migration (includes database, files, and config)"
echo "2) Wings Only Migration (configuration and nodes)"
read -p "Enter choice (1 or 2): " MIGRATION_TYPE

WINGS_FQDN=""
if [[ $MIGRATION_TYPE == "2" ]]; then
    read -p "New FQDN for Wings (e.g., wings.example.com, required for node setup in panel): " WINGS_FQDN
    if [[ -z "$WINGS_FQDN" ]]; then
        print_error "FQDN for Wings is required. Exiting."
        exit 1
    fi
fi

if [[ $MIGRATION_TYPE != "1" && $MIGRATION_TYPE != "2" ]]; then
    print_error "Invalid choice. Exiting."
    exit 1
fi

# Temporary files and directories
TEMP_DIR="/tmp/pterodactyl_migration"
BACKUP_DB="$TEMP_DIR/panel.sql"
mkdir -p $TEMP_DIR

# SSH function to execute commands on old VPS
ssh_cmd() {
    local cmd="$1"
    sshpass -p "$OLD_PW" ssh -o StrictHostKeyChecking=no -p 22 root@$OLD_IP "$cmd"
}

# Test SSH connection on port 22
print_status "Testing SSH connection to old VPS on port 22..."
if ! sshpass -p "$OLD_PW" ssh -o StrictHostKeyChecking=no -p 22 root@$OLD_IP "echo 'Connection successful'"; then
    print_error "Failed to connect to old VPS via SSH on port 22. Check IP, password, and SSH config."
    exit 1
fi
print_status "SSH connection on port 22 successful."

# Install dependencies if needed (sshpass for password auth, ufw, etc.)
apt update -qq
apt install -y sshpass ufw mariadb-server php-mysql 2>/dev/null || true  # For panel, assume MySQL is needed

# Configure UFW automatically
print_status "Configuring UFW firewall..."
ufw --force enable
ufw allow OpenSSH  # Port 22 for SSH
ufw allow 80/tcp   # HTTP for panel
ufw allow 443/tcp  # HTTPS for panel
ufw allow 2022/tcp # Wings API (NOT SSH port 22)
ufw allow 2222/tcp # Example SFTP port for Wings (adjust if needed)
ufw allow 8080/tcp # Panel fallback if non-SSL
ufw --force reload
print_status "UFW configured: SSH (22), Panel (80/443/8080), Wings (2022/2222)."

if [[ $MIGRATION_TYPE == "1" ]]; then
    print_status "Starting Full Panel Migration (using domain: $NEW_DOMAIN)..."

    # Step 1: Backup MySQL database from old VPS (assume default root pw empty; adjust if needed)
    print_status "Backing up MySQL database from old VPS..."
    ssh_cmd "mysqldump -u root -p'' pterodactyl > /tmp/panel.sql"  # DB name: pterodactyl
    scp -o StrictHostKeyChecking=no -P 22 root@$OLD_IP:/tmp/panel.sql $BACKUP_DB
    ssh_cmd "rm /tmp/panel.sql"
    print_status "Database backup transferred."

    # Step 2: Install Pterodactyl Panel basics on new VPS (simplified; follow official docs for full setup)
    print_warning "Installing Pterodactyl Panel basics (LEMP stack)..."
    apt install -y nginx php8.1-fpm php8.1-mysql php8.1-curl php8.1-mbstring php8.1-xml php8.1-zip php8.1-gd php8.1-imagick composer unzip
    systemctl enable --now nginx php8.1-fpm mariadb

    # Download and setup Panel
    cd /var/www
    wget -O panel.tar.gz "https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz"
    tar -xzf panel.tar.gz
    chmod -R 755 /var/www/pterodactyl/storage/* /var/www/pterodactyl/bootstrap/cache
    cd /var/www/pterodactyl
    composer install --no-dev --optimize-autoloader

    # Setup MySQL on new VPS
    mysql_secure_installation <<< "n\ny\ny\ny\ny\ny"  # Secure install (non-interactive)
    mysql -u root -p'' -e "CREATE DATABASE IF NOT EXISTS pterodactyl CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    mysql -u root -p'' -e "CREATE USER IF NOT EXISTS 'pterodactyl'@'localhost' IDENTIFIED BY 'strongpassword123'; GRANT ALL PRIVILEGES ON pterodactyl.* TO 'pterodactyl'@'localhost'; FLUSH PRIVILEGES;"

    # Restore DB
    mysql -u root -p'' pterodactyl < $BACKUP_DB
    print_status "Database restored."

    # Step 3: Transfer panel files
    print_status "Transferring panel files via rsync..."
    rsync -avz -e "sshpass -p '$OLD_PW' ssh -o StrictHostKeyChecking=no -p 22" root@$OLD_IP:/var/www/pterodactyl/ /var/www/pterodactyl/
    chown -R www-data:www-data /var/www/pterodactyl/

    # Step 4: Update configuration with new domain
    print_status "Updating panel configuration for domain: $NEW_DOMAIN..."
    cd /var/www/pterodactyl
    cp .env.example .env
    # Get APP_KEY from old VPS
    OLD_APP_KEY=$(ssh_cmd "grep APP_KEY /var/www/pterodactyl/.env | cut -d= -f2")
    if [[ -z "$OLD_APP_KEY" ]]; then
        print_warning "Could not fetch APP_KEY from old VPS. Generate a new one."
        php artisan key:generate --force
    else
        sed -i "s|APP_KEY=.*|APP_KEY=$OLD_APP_KEY|" .env
    fi
    sed -i "s|APP_URL=.*|APP_URL=https://$NEW_DOMAIN|" .env
    sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=strongpassword123|" .env  # Adjust to your DB pw
    chown -R www-data:www-data /var/www/pterodactyl/
    php artisan migrate --seed --force
    php artisan p:environment:setup
    php artisan p:environment:database

    # Step 5: Setup Nginx config for domain
    cat > /etc/nginx/sites-available/pterodactyl << EOF
server {
    listen 80;
    server_name $NEW_DOMAIN;
    root /var/www/pterodactyl/public;
    index index.php;
    client_max_body_size 100M;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/pterodactyl /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    nginx -t && systemctl restart nginx

    print_status "Full panel migration completed. Visit https://$NEW_DOMAIN to verify. Setup SSL (e.g., via Certbot) manually."

elif [[ $MIGRATION_TYPE == "2" ]]; then
    print_status "Starting Wings Only Migration (using FQDN: $WINGS_FQDN, API port: 2022)..."

    # Install Wings on new VPS
    print_warning "Installing Pterodactyl Wings..."
    apt install -y curl systemd
    mkdir -p /etc/pterodactyl /var/lib/pterodactyl/volumes

    # Download Wings binary
    curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64"
    chmod +x /usr/local/bin/wings

    # Create Wings config with FQDN integration (remote points to panel domain)
    WINGS_UUID=$(uuidgen)
    cat > /etc/pterodactyl/config.yml << EOF
debug: false
uuid: $WINGS_UUID
token_id: ""
token: ""
api:
  host: 0.0.0.0
  port: 2022  # Wings API port (panel communicates here, NOT SSH 22)
  ssl:
    enabled: false  # Set to true if using SSL for Wings API
allowed_origins: []
logging:
  mute: false
  level: info
  expected:
    size: 10485760  # 10MB
    age: 7
    count: 5
meta:
  token: ""
  remote: "https://$NEW_DOMAIN"  # Point to new panel domain
system:
  data: /var/lib/pterodactyl/volumes
  sftp:
    bind_port: 2222  # Separate SFTP port (not 2022, to avoid conflicts; configure per server in panel)
EOF

    # Transfer Wings config from old VPS if exists
    print_status "Transferring Wings configuration from old VPS..."
    if ssh_cmd "[ -d /etc/pterodactyl ]"; then
        rsync -avz -e "sshpass -p '$OLD_PW' ssh -o StrictHostKeyChecking=no -p 22" root@$OLD_IP:/etc/pterodactyl/ /etc/pterodactyl/
        # Update remote in config to new panel
        sed -i "s|remote: .*|remote: https://$NEW_DOMAIN|" /etc/pterodactyl/config.yml
    fi

    # Create systemd service for Wings
    cat > /etc/systemd/system/wings.service << EOF
[Unit]
Description=Pterodactyl Wings Daemon
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=/etc/pterodactyl
ExecStart=/usr/local/bin/wings
ExecReload=/bin/kill -s SIGHUP \$MAINPID
Restart=on-failure
RestartSec=5s
KillMode=mixed
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable wings
    systemctl start wings

    # Initial run to generate token (check logs)
    print_status "Wings started. Check token in logs: journalctl -u wings -f"
    print_warning "In the panel (at $NEW_DOMAIN), create/update the node with:"
    print_warning "- FQDN: $WINGS_FQDN"
    print_warning "- Behind Proxy: No (unless configured)"
    print_warning "- FQDN Port: 2022 (Wings API)"
    print_warning "- Memory/ Disk/ CPU limits as needed"
    print_warning "Copy the 'Daemon Token' from Wings logs to the panel node config."

    print_status "Wings migration completed."

else
    print_error "Invalid migration type."
    exit 1
fi

# Cleanup
rm -rf $TEMP_DIR
print_status "Migration script finished. Verify configurations, logs, and setup SSL/UFW rules manually."
print_warning "This script is simplified. For production, follow Pterodactyl docs for security, SSL (e.g., Let's Encrypt), and custom ports."
print_warning "If Wings FQDN needs DNS setup, point $WINGS_FQDN to the new VPS IP."
