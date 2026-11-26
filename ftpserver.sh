#!/usr/bin/env bash

set -euo pipefail

# Usage:
# sudo ./setup-ftp.sh PUBLIC_IP [FTP_USERNAME]

PUBLIC_IP="${1:-}"
FTP_USER="${2:-ftpuser}"

FTP_HOME="/home/${FTP_USER}"
FTP_FILES="${FTP_HOME}/files"

PASV_MIN_PORT="40000"
PASV_MAX_PORT="40100"

SSL_DIR="/etc/vsftpd/ssl"
SSL_CERT="${SSL_DIR}/vsftpd.crt"
SSL_KEY="${SSL_DIR}/vsftpd.key"

CONFIG_FILE="/etc/vsftpd/vsftpd.conf"

if [[ $EUID -ne 0 ]]; then
    echo "Run this script as root or with sudo."
    exit 1
fi

if [[ -z "$PUBLIC_IP" ]]; then
    echo "Usage: $0 PUBLIC_IP [FTP_USERNAME]"
    exit 1
fi

if ! [[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "Invalid IPv4 address: $PUBLIC_IP"
    exit 1
fi

echo "[1/9] Installing required packages..."

dnf install -y vsftpd openssl firewalld policycoreutils

echo "[2/9] Enabling firewalld..."

systemctl enable --now firewalld

echo "[3/9] Creating FTP user..."

if ! id "$FTP_USER" &>/dev/null; then
    useradd \
        --home-dir "$FTP_HOME" \
        --create-home \
        --shell /sbin/nologin \
        "$FTP_USER"
else
    echo "User $FTP_USER already exists."
fi

echo "Set FTP password for user: $FTP_USER"
passwd "$FTP_USER"

echo "[4/9] Configuring FTP directories..."

mkdir -p "$FTP_FILES"

# The chroot root must not be writable by the FTP user.
chown root:root "$FTP_HOME"
chmod 755 "$FTP_HOME"

# User can upload files only inside this directory.
chown "$FTP_USER:$FTP_USER" "$FTP_FILES"
chmod 750 "$FTP_FILES"

echo "[5/9] Creating SSL certificate..."

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

echo "[6/9] Backing up existing configuration..."

if [[ -f "$CONFIG_FILE" ]]; then
    cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d-%H%M%S)"
fi

echo "[7/9] Writing vsftpd configuration..."

cat > "$CONFIG_FILE" <<EOF
# Standalone FTP server
listen=NO
listen_ipv6=YES

# Local users
local_enable=YES
write_enable=YES
local_umask=022

# Chroot
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

echo "[8/9] Configuring firewall and SELinux..."

firewall-cmd --permanent --add-port=21/tcp
firewall-cmd --permanent --add-port="${PASV_MIN_PORT}-${PASV_MAX_PORT}/tcp"
firewall-cmd --reload

# Enable relevant SELinux booleans only if they exist.
if getsebool ftp_home_dir &>/dev/null; then
    setsebool -P ftp_home_dir on
fi

if getsebool ftpd_use_passive_mode &>/dev/null; then
    setsebool -P ftpd_use_passive_mode on
fi

restorecon -RF "$FTP_HOME" "$SSL_DIR"

echo "[9/9] Starting vsftpd..."

systemctl enable --now vsftpd
systemctl restart vsftpd

echo
echo "======================================"
echo " FTP server setup completed"
echo "======================================"
echo "Server IP:      $PUBLIC_IP"
echo "FTP username:   $FTP_USER"
echo "FTP home:      $FTP_HOME"
echo "Upload folder:  $FTP_FILES"
echo "Protocol:       Explicit FTPS"
echo "Port:           21"
echo "Passive ports:  ${PASV_MIN_PORT}-${PASV_MAX_PORT}"
echo "SSL certificate: $SSL_CERT"
echo
echo "Check service:"
echo "  systemctl status vsftpd"
echo
echo "Check listening ports:"
echo "  ss -lntp | grep -E ':21|:400[0-9][0-9]'"
echo "======================================"