#!/usr/bin/env bash

set -euo pipefail

FTP_CONFIG="/etc/vsftpd/vsftpd.conf"
SSL_DIR="/etc/vsftpd/ssl"
SSL_CERT="${SSL_DIR}/vsftpd.crt"
SSL_KEY="${SSL_DIR}/vsftpd.key"

PASV_MIN_PORT="40000"
PASV_MAX_PORT="40100"

# ----------------------------------------
# Check root
# ----------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "Please run this script with sudo."
    exit 1
fi

# ----------------------------------------
# Install FTP server
# ----------------------------------------

install_ftp() {
    local PUBLIC_IP="${1:-}"

    if [[ -z "$PUBLIC_IP" ]]; then
        echo "Usage: $0 install PUBLIC_IP"
        exit 1
    fi

    if ! [[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "Invalid IPv4 address."
        exit 1
    fi

    echo "[1/7] Installing packages..."

    dnf install -y vsftpd openssl firewalld policycoreutils

    echo "[2/7] Enabling firewalld..."

    systemctl enable --now firewalld

    echo "[3/7] Creating SSL certificate..."

    mkdir -p "$SSL_DIR"
    chmod 700 "$SSL_DIR"

    if [[ ! -f "$SSL_CERT" || ! -f "$SSL_KEY" ]]; then
        openssl req \
            -x509 \
            -nodes \
            -days 825 \
            -newkey rsa:2048 \
            -keyout "$SSL_KEY" \
            -out "$SSL_CERT" \
            -subj "/CN=${PUBLIC_IP}" \
            -addext "subjectAltName=IP:${PUBLIC_IP}"
    fi

    chmod 600 "$SSL_KEY"
    chmod 644 "$SSL_CERT"

    echo "[4/7] Backing up configuration..."

    if [[ -f "$FTP_CONFIG" ]]; then
        cp "$FTP_CONFIG" \
            "${FTP_CONFIG}.backup.$(date +%Y%m%d-%H%M%S)"
    fi

    echo "[5/7] Configuring vsftpd..."

    cat > "$FTP_CONFIG" <<EOF
# Standalone FTP server
listen=NO
listen_ipv6=YES

# Local users
local_enable=YES
write_enable=YES
local_umask=022

# User directories
chroot_local_user=YES
allow_writeable_chroot=NO
user_sub_token=\$USER
local_root=/home/\$USER

# Authentication
anonymous_enable=NO
pam_service_name=vsftpd

# Passive mode
pasv_enable=YES
pasv_min_port=${PASV_MIN_PORT}
pasv_max_port=${PASV_MAX_PORT}
pasv_address=${PUBLIC_IP}

# Explicit FTPS
ssl_enable=YES
allow_anon_ssl=NO
force_local_logins_ssl=YES
force_local_data_ssl=YES

rsa_cert_file=${SSL_CERT}
rsa_private_key_file=${SSL_KEY}

ssl_sslv2=NO
ssl_sslv3=NO
ssl_tlsv1=NO
ssl_tlsv1_1=NO
ssl_tlsv1_2=YES
ssl_tlsv1_3=YES

require_ssl_reuse=NO

# Logging
xferlog_enable=YES
log_ftp_protocol=YES
xferlog_std_format=YES
EOF

    echo "[6/7] Configuring firewall and SELinux..."

    firewall-cmd --permanent --add-port=21/tcp
    firewall-cmd --permanent \
        --add-port="${PASV_MIN_PORT}-${PASV_MAX_PORT}/tcp"
    firewall-cmd --reload

    if getsebool ftpd_use_passive_mode &>/dev/null; then
        setsebool -P ftpd_use_passive_mode on
    fi

    restorecon -RF "$SSL_DIR"

    echo "[7/7] Starting vsftpd..."

    systemctl enable --now vsftpd
    systemctl restart vsftpd

    echo
    echo "FTP server installation completed."
    echo "Server IP: $PUBLIC_IP"
    echo "Protocol: Explicit FTPS"
    echo "Port: 21"
    echo "Passive ports: ${PASV_MIN_PORT}-${PASV_MAX_PORT}"
    echo
    echo "Now create users with:"
    echo "  $0 add-user USERNAME"
}

# ----------------------------------------
# Add FTP user
# ----------------------------------------

add_ftp_user() {
    local FTP_USER="${1:-}"
    local FTP_HOME
    local FTP_FILES
    local FTP_PASSWORD
    local FTP_PASSWORD_CONFIRM

    if [[ -z "$FTP_USER" ]]; then
        echo "Usage: $0 add-user USERNAME"
        exit 1
    fi

    if ! [[ "$FTP_USER" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        echo "Invalid username."
        echo "Use only letters, numbers, dot, underscore or hyphen."
        exit 1
    fi

    if id "$FTP_USER" &>/dev/null; then
        echo "User already exists: $FTP_USER"
        exit 1
    fi

    FTP_HOME="/home/${FTP_USER}"
    FTP_FILES="${FTP_HOME}/files"

    echo "Enter password for ${FTP_USER}:"
    read -r -s FTP_PASSWORD
    echo

    echo "Confirm password:"
    read -r -s FTP_PASSWORD_CONFIRM
    echo

    if [[ -z "$FTP_PASSWORD" ]]; then
        echo "Password cannot be empty."
        exit 1
    fi

    if [[ "$FTP_PASSWORD" != "$FTP_PASSWORD_CONFIRM" ]]; then
        echo "Passwords do not match."
        exit 1
    fi

    echo "Creating FTP user..."

    useradd \
        --create-home \
        --home-dir "$FTP_HOME" \
        --shell /sbin/nologin \
        "$FTP_USER"

    printf '%s:%s\n' "$FTP_USER" "$FTP_PASSWORD" | chpasswd

    unset FTP_PASSWORD FTP_PASSWORD_CONFIRM

    echo "Configuring directories..."

    mkdir -p "$FTP_FILES"

    # Chroot root must not be writable by the FTP user.
    chown root:root "$FTP_HOME"
    chmod 755 "$FTP_HOME"

    # Writable directory for uploads.
    chown "$FTP_USER:$FTP_USER" "$FTP_FILES"
    chmod 750 "$FTP_FILES"

    restorecon -RF "$FTP_HOME"

    echo
    echo "FTP user created successfully."
    echo "Username: $FTP_USER"
    echo "Home: $FTP_HOME"
    echo "Upload directory: $FTP_FILES"
    echo
    echo "The user can upload files inside /files."
}

# ----------------------------------------
# Main
# ----------------------------------------

ACTION="${1:-}"

case "$ACTION" in
    install)
        install_ftp "${2:-}"
        ;;

    add-user)
        add_ftp_user "${2:-}"
        ;;

    *)
        echo "Usage:"
        echo "  $0 install PUBLIC_IP"
        echo "  $0 add-user USERNAME"
        exit 1
        ;;
esac