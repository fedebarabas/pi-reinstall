#!/usr/bin/env bash
# =============================================================================
# NEXTCLOUDPI SERVER — FULL REINSTALL (includes RetroPie)
# =============================================================================
# Host    : nextcloudpi   (192.168.1.6, eth0 static)
# OS      : Debian 12 Bookworm aarch64
# NCP     : v1.57.1
# Domains : erebor.home.kg  fulbo.home.kg  mellon.home.kg
# Generated: 2026-05-31
#
# SCENARIO: SD card (mmcblk0) failed.
#           /storage (sda1, UUID d15012d9-...) and /backup (sdb1, UUID
#           51d71388-...) are assumed INTACT and connected.
#
# USAGE:
#   1. Flash Raspberry Pi OS Lite 64-bit (Bookworm) onto a new SD card.
#   2. Boot, SSH in (user pi), then:
#        sudo bash reinstall-full.sh 2>&1 | tee /tmp/reinstall.log
#
# MANUAL STEPS (search "# TODO:" below):
#   - Tailscale auth key
#   - WiFi password (NetworkManager)
#   - Git repos for grocery-app, translation-tool, prode-mundial, finance-tracker
#   - translation-tool .env (Google OAuth, API keys, etc.)
#   - /etc/apache2/.htpasswd-translation (Basic Auth for mellon.home.kg)
#   - update-mellon-dns.sh and update-ddns.sh scripts
#   - NCP database restore (via ncp-restore or web UI at :4443)
#   - RetroPie ROMs and BIOS from backup
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
todo()    { echo -e "${RED}[TODO]${NC}  $*"; }
section() { echo -e "\n${BOLD}══════════════════════════════════════════════════${NC}"; echo -e "${BOLD}  $*${NC}"; echo -e "${BOLD}══════════════════════════════════════════════════${NC}"; }

[[ $EUID -eq 0 ]] || { echo "Run as root:  sudo bash $0"; exit 1; }

PI_USER=pi
STORAGE_UUID="d15012d9-ba6d-47b9-b806-1b33716f3b8e"
BACKUP_UUID="51d71388-a181-4902-8c63-68e1a72df831"

# =============================================================================
# 0. PRE-FLIGHT
# =============================================================================
section "0. Pre-flight checks"

mkdir -p /storage /backup

if ! blkid | grep -q "$STORAGE_UUID"; then
    warn "Storage drive (sda1 / /storage) NOT detected — connect it first."
    read -rp "Continue anyway? [y/N] " _ans; [[ "${_ans,,}" == y ]] || exit 1
fi
if ! blkid | grep -q "$BACKUP_UUID"; then
    warn "Backup drive (sdb1 / /backup) NOT detected."
fi

# =============================================================================
# 1. HOSTNAME, LOCALE, TIMEZONE
# =============================================================================
section "1. Hostname / locale / timezone"

hostnamectl set-hostname nextcloudpi

cat > /etc/hostname <<'EOF'
nextcloudpi
EOF

cat > /etc/hosts <<'EOF'
127.0.0.1   localhost
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters

127.0.1.1   nextcloudpi raspberrypi
192.168.1.6 erebor.home.kg
EOF

sed -i 's/^# \(en_GB\.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
update-locale LANG=en_GB.UTF-8 LC_ALL=en_GB.UTF-8

timedatectl set-timezone Europe/Stockholm

cat > /etc/default/keyboard <<'EOF'
XKBMODEL="pc105"
XKBLAYOUT="us"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF
setupcon --force --save 2>/dev/null || true

# =============================================================================
# 2. NETWORK — STATIC IP ON ETH0
# =============================================================================
section "2. Network"

cat > /etc/network/interfaces <<'EOF'
# ncp-config generated
source /etc/network/interfaces.d/*

# Local loopback
auto lo
iface lo inet loopback

# Interface eth0 — static
auto eth0
allow-hotplug eth0
iface eth0 inet static
    address 192.168.1.6
    netmask 255.255.255.0
    gateway 192.168.1.1
    dns-nameservers 192.168.1.1 8.8.8.8
EOF

# wlan0 is managed by NetworkManager (RetroPie-WiFi profile)
# TODO: After boot, re-enter WiFi credentials:
#   nmcli dev wifi connect "<SSID>" password "<PASS>"
todo "Set WiFi credentials via:  nmcli dev wifi connect \"<SSID>\" password \"<PASS>\""

# =============================================================================
# 3. FSTAB — EXTERNAL DRIVES
# =============================================================================
section "3. fstab"

grep -qF "$STORAGE_UUID" /etc/fstab || \
    echo "UUID=$STORAGE_UUID /storage   ext4   defaults 0 2" >> /etc/fstab

grep -qF "$BACKUP_UUID" /etc/fstab || \
    echo "UUID=$BACKUP_UUID /backup    ext4   defaults 0 2" >> /etc/fstab

mount -a
info "Mounted: $(df -h /storage /backup 2>/dev/null | tail -2 || echo 'check manually')"

# =============================================================================
# 4. PACKAGES
# =============================================================================
section "4. System packages"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# Add Docker repo
if ! command -v docker &>/dev/null; then
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o /usr/share/keyrings/docker.gpg
    echo "deb [arch=arm64 signed-by=/usr/share/keyrings/docker.gpg] \
        https://download.docker.com/linux/debian bookworm stable" \
        > /etc/apt/sources.list.d/docker.list
fi

# Add Tailscale repo
if ! command -v tailscale &>/dev/null; then
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
        | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-list \
        | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
fi

apt-get update -qq

apt-get install -y --no-install-recommends \
    build-essential cmake make gcc gdb meson ninja-build pkg-config \
    manpages-dev devscripts dh-autoreconf debhelper \
    curl wget git vim-tiny nano tmux htop mc ncdu jq xmlstarlet \
    pv lbzip2 pigz p7zip-full zip unzip rsync \
    strace net-tools iproute2 iputils-ping dnsutils ethtool whois \
    python3 python3-pip python3-venv python3-certbot-apache \
    python3-gpiozero python3-libgpiod python3-pigpio python3-rpi-lgpio \
    python3-sdl2 python3-smbus2 python3-spidev python3-systemd \
    python3-uinput python3-urwid python-is-python3 \
    nodejs npm \
    apache2 libapache2-mod-authnz-external libapache2-mod-security2 \
    pwauth modsecurity-crs certbot python3-certbot-apache ssl-cert \
    php8.3 php8.3-fpm php8.3-cli php8.3-common php8.3-apcu php8.3-bcmath \
    php8.3-bz2 php8.3-curl php8.3-gd php8.3-gmp php8.3-intl php8.3-ldap \
    php8.3-mbstring php8.3-mysql php8.3-opcache php8.3-redis php8.3-xml php8.3-zip \
    mariadb-server redis-server postfix \
    docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin \
    exfat-fuse exfatprogs ntfs-3g nfs-common nfs-kernel-server \
    cifs-utils btrfs-progs dosfstools parted \
    samba smbclient \
    minidlna mkvtoolnix vlc \
    dnsmasq avahi-daemon fail2ban ufw \
    cups hplip printer-driver-gutenprint \
    smartmontools prometheus-node-exporter lynis debsecan debsums \
    libpam-chksshpwd \
    raspi-config raspi-firmware raspi-utils rpi-eeprom rpi-update \
    dphys-swapfile fake-hwclock pigpio gpiod \
    udisks2 udiskie inotify-tools miniupnpc gocryptfs \
    wpa_supplicant network-manager tailscale \
    subversion \
    v4l-utils rpicam-apps-core \
    linux-headers-rpi-v8 linux-headers-rpi-2712 \
    linux-image-rpi-v8 linux-image-rpi-2712 \
    \
    `# --- RetroPie build deps ---` \
    lua5.1 luajit \
    libavcodec-dev libavdevice-dev libavformat-dev \
    libboost-filesystem-dev \
    libcurl4-openssl-dev \
    libdrm-dev libegl1-mesa-dev libgbm-dev \
    libgl1-mesa-dev libgles2-mesa-dev libglu1-mesa-dev \
    libfmt-dev libfreeimage-dev libfreetype-dev \
    libibus-1.0-dev \
    libsdl2-dev libsdl2-2.0-0 \
    libsamplerate0-dev libsndio-dev libspeexdsp-dev \
    libudev-dev libusb-1.0-0-dev \
    libvlc-dev libvlccore-dev \
    libx11-dev libx11-xcb-dev libxcursor-dev libxext-dev \
    libxi-dev libxinerama-dev libxkbcommon-dev libxrandr-dev \
    libxss-dev libxt-dev libxv-dev libxxf86vm-dev \
    libasound2-dev rapidjson-dev fcitx-libs-dev \
    kms++-utils

# Ensure Node.js v20
NODE_VER=$(node --version 2>/dev/null | grep -oP '\d+' | head -1 || echo 0)
if (( NODE_VER < 20 )); then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
fi

# =============================================================================
# 5. NEXTCLOUDPI
# =============================================================================
section "5. NextcloudPi installation (v1.57.1)"

info "This will install Nextcloud, MariaDB, PHP-FPM, Redis, and Apache NC vhost."
info "Estimated time: 15-30 minutes."

curl -sSL https://raw.githubusercontent.com/nextcloud/nextcloudpi/master/install.sh | bash

# NCP sets up /var/www/nextcloud, MariaDB, Redis, /var/www/ncp-web, and
# the ncp.conf Apache vhost (port 4443).

# =============================================================================
# 6. NEXTCLOUD CONFIG RESTORATION
# =============================================================================
section "6. Nextcloud config.php + DB restoration"

# Data directory is on /storage (surviving drive) — no data loss there.
# We need to restore the database and config.php secrets.

# Look for NCP backup on /backup
LATEST_BACKUP=$(find /backup -maxdepth 3 \( -name "*.tar" -o -name "*.zip" \) 2>/dev/null | sort | tail -1 || true)
if [[ -n "$LATEST_BACKUP" ]]; then
    info "Found NCP backup: $LATEST_BACKUP"
    info "Restore it via NCP web UI (https://192.168.1.6:4443) OR:"
    info "  sudo ncp-restore \"$LATEST_BACKUP\""
else
    warn "No NCP backup found in /backup. Restore DB manually."
fi

# Write config.php (secrets from last known working configuration)
info "Writing /var/www/nextcloud/config/config.php ..."
cat > /var/www/nextcloud/config/config.php <<'NCCONF'
<?php
$CONFIG = array (
  'passwordsalt' => 'Ia3SeHyMq5t7xJ8BQkXcm0yIzGFewJ',
  'secret' => 'rl3Dlil05cw1+fBLrZ2QqHOj1IQuVrtxVgGbg8RQe4WckEBe',
  'trusted_domains' =>
  array (
    0 => 'localhost',
    1 => '192.168.1.6',
    2 => 'erebor.home.kg',
    3 => 'erebor.home.kg',
    5 => 'nextcloudpi.local',
    7 => 'nextcloudpi',
    8 => 'nextcloudpi.lan',
    11 => '181.93.110.236',
    14 => 'nextcloudpi',
  ),
  'datadirectory' => '/storage/nextcloud/data',
  'dbtype' => 'mysql',
  'version' => '33.0.4.1',
  'overwrite.cli.url' => 'https://erebor.home.kg/',
  'dbname' => 'nextcloud',
  'dbhost' => 'localhost',
  'dbport' => '',
  'dbtableprefix' => 'oc_',
  'mysql.utf8mb4' => true,
  'dbuser' => 'ncadmin',
  'dbpassword' => 'Qkb1Ic7rxBqKsNDYD4mRQC+fE9R3lNBejI0VOTpFe/g=',
  'installed' => true,
  'instanceid' => 'ocebr7iiyaae',
  'memcache.local' => '\\OC\\Memcache\\Redis',
  'memcache.locking' => '\\OC\\Memcache\\Redis',
  'redis' =>
  array (
    'host' => '/var/run/redis/redis.sock',
    'port' => 0,
    'timeout' => 0.0,
    'password' => 'FJC6SuQI1O/7+TMZAGhqzGQf/7X4MYXfFRG7XmOQtlw=',
  ),
  'tempdirectory' => '/storage/nextcloud/data/tmp',
  'mail_smtpmode' => 'sendmail',
  'mail_smtpauthtype' => 'LOGIN',
  'mail_from_address' => 'noreply',
  'mail_domain' => 'nextcloudpi.com',
  'preview_max_x' => 2048,
  'preview_max_y' => 2048,
  'jpeg_quality' => 60,
  'overwriteprotocol' => 'https',
  'maintenance' => false,
  'logfile' => '/storage/nextcloud/data/data/nextcloud.log',
  'trusted_proxies' =>
  array (
    11 => '127.0.0.1',
    12 => '::1',
    14 => '181.93.110.236',
  ),
  'loglevel' => '2',
  'log_type' => 'file',
  'htaccess.RewriteBase' => '/',
  'memories.db.triggers.fcu' => true,
  'memories.exiftool' => '/var/www/nextcloud/apps/memories/bin-ext/exiftool-aarch64-glibc',
  'memories.vod.path' => '/var/www/nextcloud/apps/memories/bin-ext/go-vod-aarch64',
  'app_install_overwrite' =>
  array (
    0 => 'files_rightclick',
    1 => 'transmission',
    2 => 'weather',
    3 => 'podcast',
  ),
  'theme' => '',
);
NCCONF
chown www-data:www-data /var/www/nextcloud/config/config.php
chmod 640 /var/www/nextcloud/config/config.php

# After DB is restored, run repair and file scan
info "Running Nextcloud maintenance (after DB restore these should succeed)..."
sudo -u www-data php /var/www/nextcloud/occ maintenance:repair 2>/dev/null || \
    warn "occ maintenance:repair failed — run manually after DB restoration"
sudo -u www-data php /var/www/nextcloud/occ files:scan --all 2>/dev/null || true

# =============================================================================
# 7. APACHE VIRTUAL HOSTS
# =============================================================================
section "7. Apache virtual hosts"

a2enmod ssl proxy proxy_http proxy_wstunnel rewrite headers remoteip http2
a2enconf php8.3-fpm

# --- Nextcloud (001-nextcloud.conf) — NCP generates this, but ensure it exists
# NCP installer creates this; if missing recreate:
if [[ ! -f /etc/apache2/sites-available/001-nextcloud.conf ]]; then
cat > /etc/apache2/sites-available/001-nextcloud.conf <<'EOF'
<VirtualHost _default_:80>
  DocumentRoot /var/www/nextcloud
  <IfModule mod_rewrite.c>
    RewriteEngine On
    RewriteRule ^.well-known/acme-challenge/ - [L]
    RewriteCond %{HTTPS} !=on
    RewriteRule ^/?(.*) https://%{SERVER_NAME}/$1 [R,L]
  </IfModule>
  <Directory /var/www/nextcloud/>
    Options +FollowSymlinks
    AllowOverride All
    <IfModule mod_dav.c>
      Dav off
    </IfModule>
    LimitRequestBody 0
  </Directory>
</VirtualHost>
### DO NOT EDIT — AUTO GENERATED BY NCP ###
<IfModule mod_ssl.c>
  <VirtualHost _default_:443>
    DocumentRoot /var/www/nextcloud
    ServerName erebor.home.kg
    CustomLog /var/log/apache2/nc-access.log combined
    ErrorLog  /var/log/apache2/nc-error.log
    SSLEngine on
    SSLProxyEngine on
    SSLCertificateFile   /etc/letsencrypt/live/erebor.home.kg/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/erebor.home.kg/privkey.pem
    ProxyPass /push/ws ws://127.0.0.1:7867/ws
    ProxyPass /push/ http://127.0.0.1:7867/
    ProxyPassReverse /push/ http://127.0.0.1:7867/
    RemoteIPHeader X-Forwarded-For
  </VirtualHost>
  <Directory /var/www/nextcloud/>
    Options +FollowSymlinks
    AllowOverride All
    <IfModule mod_dav.c>
      Dav off
    </IfModule>
    LimitRequestBody 0
    SSLRenegBufferSize 10486000
  </Directory>
  <IfModule mod_headers.c>
    Header always set Strict-Transport-Security "max-age=15768000; includeSubDomains"
  </IfModule>
</IfModule>
EOF
    a2ensite 001-nextcloud.conf
fi

# --- fulbo.home.kg → Docker container on port 1986 ---
cat > /etc/apache2/sites-available/fulbo.conf <<'EOF'
<VirtualHost *:80>
    ServerName fulbo.home.kg
    ProxyPreserveHost On
    ProxyPass        / http://127.0.0.1:1986/
    ProxyPassReverse / http://127.0.0.1:1986/
    ErrorLog  ${APACHE_LOG_DIR}/fulbo-error.log
    CustomLog ${APACHE_LOG_DIR}/fulbo-access.log combined
    RewriteEngine on
    RewriteCond %{SERVER_NAME} =fulbo.home.kg
    RewriteRule ^ https://%{SERVER_NAME}%{REQUEST_URI} [END,NE,R=permanent]
</VirtualHost>
EOF

cat > /etc/apache2/sites-available/fulbo-le-ssl.conf <<'EOF'
<IfModule mod_ssl.c>
<VirtualHost *:443>
    ServerName fulbo.home.kg
    ProxyPreserveHost On
    ProxyPass        / http://127.0.0.1:1986/
    ProxyPassReverse / http://127.0.0.1:1986/
    ErrorLog  ${APACHE_LOG_DIR}/fulbo-error.log
    CustomLog ${APACHE_LOG_DIR}/fulbo-access.log combined
    SSLCertificateFile /etc/letsencrypt/live/fulbo.home.kg/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/fulbo.home.kg/privkey.pem
    Include /etc/letsencrypt/options-ssl-apache.conf
</VirtualHost>
</IfModule>
EOF

# --- mellon.home.kg → translation-tool on port 3001 ---
cat > /etc/apache2/sites-available/translation-tool.conf <<'EOF'
<VirtualHost *:80>
    ServerName mellon.home.kg
    Redirect permanent / https://mellon.home.kg/
</VirtualHost>

<VirtualHost *:443>
    ServerName mellon.home.kg
    SSLEngine on
    SSLCertificateFile     /etc/letsencrypt/live/mellon.home.kg/fullchain.pem
    SSLCertificateKeyFile  /etc/letsencrypt/live/mellon.home.kg/privkey.pem

    <Location />
        AuthType Basic
        AuthName "Translation Tool"
        AuthUserFile /etc/apache2/.htpasswd-translation
        Require valid-user
    </Location>

    ProxyPreserveHost On
    ProxyPass        / http://127.0.0.1:3001/
    ProxyPassReverse / http://127.0.0.1:3001/
    RequestHeader set X-Forwarded-Proto "https"

    ErrorLog  ${APACHE_LOG_DIR}/translation-tool-error.log
    CustomLog ${APACHE_LOG_DIR}/translation-tool-access.log combined
</VirtualHost>
EOF

# --- NCP web UI (port 4443) — created by NCP installer ---
# ncp.conf is managed by NCP; only write if missing
if [[ ! -f /etc/apache2/sites-available/ncp.conf ]]; then
cat > /etc/apache2/sites-available/ncp.conf <<'EOF'
Listen 4443
<VirtualHost _default_:4443>
  DocumentRoot /var/www/ncp-web
  SSLEngine on
  SSLCertificateFile /etc/letsencrypt/live/erebor.home.kg/fullchain.pem
  SSLCertificateKeyFile /etc/letsencrypt/live/erebor.home.kg/privkey.pem
  <IfModule mod_headers.c>
    Header always set Strict-Transport-Security "max-age=15768000; includeSubDomains"
  </IfModule>
  TimeOut 172800
  <IfModule mod_authnz_external.c>
    DefineExternalAuth pwauth pipe /usr/sbin/pwauth
  </IfModule>
</VirtualHost>
<Directory /var/www/ncp-web/>
  AuthType Basic
  AuthName "ncp-web login"
  AuthBasicProvider external
  AuthExternal pwauth
  <RequireAll>
   <RequireAny>
      Require host localhost
      Require local
      Require ip 192.168
      Require ip 172
      Require ip 10
      Require ip fe80::/10
      Require ip fd00::/8
   </RequireAny>
   Require user ncp
  </RequireAll>
</Directory>
EOF
    a2ensite ncp.conf
fi

# --- Status page (port 8099) ---
cat > /etc/apache2/sites-available/status.conf <<'EOF'
Listen 8099
<VirtualHost *:8099>
    DocumentRoot /var/www/html
    <Directory /var/www/html>
        Options -Indexes
        AllowOverride None
        Require all granted
    </Directory>
</VirtualHost>
EOF

a2ensite fulbo.conf fulbo-le-ssl.conf translation-tool.conf status.conf

systemctl reload apache2

todo "Recreate /etc/apache2/.htpasswd-translation:"
todo "  htpasswd -c /etc/apache2/.htpasswd-translation <USERNAME>"
todo "Issue TLS certs (after DNS is working):"
todo "  certbot --apache -d erebor.home.kg -d fulbo.home.kg -d mellon.home.kg"

# =============================================================================
# 8. DNSMASQ
# =============================================================================
section "8. Dnsmasq"

cat > /etc/dnsmasq.conf <<'EOF'
interface=eth0
domain-needed
bogus-priv
no-poll
no-resolv
cache-size=150
server=8.8.8.8
address=/erebor.home.kg/192.168.1.6
EOF

systemctl enable dnsmasq
systemctl restart dnsmasq

# =============================================================================
# 9. SAMBA
# =============================================================================
section "9. Samba"

cat > /etc/samba/smb.conf <<'EOF'
[global]
   protocol = SMB3
   workgroup = WORKGROUP
   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file
   panic action = /usr/share/samba/panic-action %d
   server role = standalone server
   obey pam restrictions = yes
   unix password sync = yes
   passwd program = /usr/bin/passwd %u
   passwd chat = *Enter\snew\s*\spassword:* %n\n *Retype\snew\s*\spassword:* %n\n *password\supdated\ssuccessfully* .
   pam password change = yes
   map to guest = bad user
   usershare allow guests = yes

[printers]
   comment = All Printers
   browseable = no
   path = /var/spool/samba
   printable = yes
   guest ok = yes
   read only = yes
   create mask = 0700

[print$]
   comment = Printer Drivers
   path = /var/lib/samba/printers
   browseable = yes
   read only = no
   guest ok = no
EOF

systemctl enable smbd nmbd
systemctl restart smbd nmbd

# =============================================================================
# 10. MINIDLNA
# =============================================================================
section "10. MiniDLNA"

cat > /etc/minidlna.conf <<'EOF'
media_dir=V,/storage/media/movies
media_dir=V,/storage/media/series
port=8200
friendly_name=RaspPIMedia
album_art_names=Cover.jpg/cover.jpg/AlbumArtSmall.jpg/albumartsmall.jpg
album_art_names=AlbumArt.jpg/albumart.jpg/Album.jpg/album.jpg
album_art_names=Folder.jpg/folder.jpg/Thumb.jpg/thumb.jpg
EOF

systemctl enable minidlna
systemctl restart minidlna

# =============================================================================
# 11. FAIL2BAN
# =============================================================================
section "11. Fail2ban"

cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
ignoreip = 127.0.0.1/8
bantime  = 600
findtime = 600
maxretry = 6
banaction  = iptables-multiport
protocol   = tcp
chain      = INPUT
action_    = %(banaction)s[name=%(__name__)s, port="%(port)s", protocol="%(protocol)s", chain="%(chain)s"]
action = %(action_)s

[ssh]
enabled  = true
port     = ssh
filter   = sshd
backend  = systemd
logpath  = /var/log/auth.log
maxretry = 6

[nextcloud]
enabled  = true
port     = http,https
filter   = nextcloud
logpath  = /storage/nextcloud/data/data/nextcloud.log
maxretry = 6
backend  = auto

[ufwban]
enabled = true
port    = ssh, http, https
filter  = ufwban
logpath = /var/log/ufw.log
action  = ufw
backend = auto
EOF

systemctl enable fail2ban
systemctl restart fail2ban

# =============================================================================
# 12. PROMETHEUS NODE EXPORTER
# =============================================================================
section "12. Prometheus node exporter"

cat > /etc/default/prometheus-node-exporter <<'EOF'
ARGS="--collector.filesystem.ignored-mount-points=\"^/(dev|proc|run|sys|mnt|var/log|var/lib/docker)($|/)\""
EOF

systemctl enable prometheus-node-exporter
systemctl restart prometheus-node-exporter

# =============================================================================
# 13. DOCKER — main stack (Transmission + Homepage)
# =============================================================================
section "13. Docker"

usermod -aG docker "$PI_USER"
mkdir -p /opt/stacks/transmission /opt/stacks/homepage/config

cat > /home/$PI_USER/docker-compose.yml <<'DCEOF'
services:
    transmission-openvpn:
        cap_add:
            - NET_ADMIN
        volumes:
            - '/storage/media/:/data'
            - '/opt/stacks/transmission/:/config'
        environment:
            - OPENVPN_PROVIDER=SURFSHARK
            - OPENVPN_CONFIG=se-sto.prod.surfshark.com_tcp
            - OPENVPN_USERNAME=7vZT9JUCz3crUrXUMCJPPtCY
            - OPENVPN_PASSWORD=XTppqqSZhrjtbBD7UYLaRrF4
            - LOCAL_NETWORK=192.168.0.0/16
            - TRANSMISSION_DOWNLOAD_DIR=/data
            - TRANSMISSION_INCOMPLETE_DIR_ENABLED=false
            - TRANSMISSION_TRASH_CAN_ENABLED=true
        logging:
            driver: json-file
            options:
                max-size: 10m
        ports:
            - '9091:9091'
        image: haugene/transmission-openvpn
        restart: always

    homepage:
        image: ghcr.io/gethomepage/homepage:latest
        container_name: homepage
        ports:
            - 3000:3000
        volumes:
            - /opt/stacks/homepage/config:/app/config
            - /var/run/docker.sock:/var/run/docker.sock:ro
            - /storage:/storage:ro
            - /backup:/backup:ro
        environment:
            - HOMEPAGE_ALLOWED_HOSTS=192.168.1.6:3000
        restart: unless-stopped
DCEOF
chown "$PI_USER:$PI_USER" /home/$PI_USER/docker-compose.yml

# prode-mundial stack — TODO: restore from git/backup
mkdir -p /home/$PI_USER/prode-mundial
todo "Clone/restore prode-mundial to /home/pi/prode-mundial/ (includes docker-compose.yml)"
todo "Then run: cd /home/pi/prode-mundial && docker compose up -d"
todo "It exposes port 1986 (reverse proxied as fulbo.home.kg)"

# Start main services
info "Starting main Docker stack (transmission + homepage)..."
cd /home/$PI_USER
sudo -u "$PI_USER" docker compose up -d || warn "docker compose failed — re-run after reboot"

# =============================================================================
# 14. CUSTOM APP — FINANCE TRACKER
# =============================================================================
section "14. Finance Tracker (Python/Gunicorn, port 5000)"

todo "Clone finance-tracker repo to /home/pi/finance-tracker"
todo "Then:  cd /home/pi/finance-tracker && python3 -m venv venv && venv/bin/pip install -r requirements.txt"

cat > /etc/systemd/system/finance-tracker.service <<'EOF'
[Unit]
Description=Finance Tracker
After=network.target

[Service]
User=pi
WorkingDirectory=/home/pi/finance-tracker
ExecStart=/home/pi/finance-tracker/venv/bin/gunicorn -w 1 -b 0.0.0.0:5000 app:app
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable finance-tracker

# =============================================================================
# 15. CUSTOM APP — GROCERY APP
# =============================================================================
section "15. Grocery App (Node.js)"

todo "Clone/restore grocery-app to /home/pi/grocery-app"
todo "Then:  cd /home/pi/grocery-app && npm install"

cat > /etc/systemd/system/grocery.service <<'EOF'
[Unit]
Description=Grocery App
After=network.target

[Service]
WorkingDirectory=/home/pi/grocery-app
ExecStart=/usr/bin/node server.js
Restart=always
User=pi

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable grocery

# =============================================================================
# 16. CUSTOM APP — TRANSLATION TOOL
# =============================================================================
section "16. Translation Tool (Node.js, port 3001)"

todo "Clone translation-tool to /home/pi/translation-tool"
todo "Then:  cd /home/pi/translation-tool && npm install"
todo "Restore /home/pi/translation-tool/.env  (Google OAuth credentials, API keys)"

cat > /etc/systemd/system/translation-tool.service <<'EOF'
[Unit]
Description=Translation Tool (Node.js)
After=network.target

[Service]
Type=simple
User=pi
WorkingDirectory=/home/pi/translation-tool
EnvironmentFile=/home/pi/translation-tool/.env
ExecStart=/usr/bin/node server.js
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable translation-tool

# =============================================================================
# 17. NEXTCLOUD NOTIFY_PUSH SERVICE
# =============================================================================
section "17. Nextcloud notify_push"

cat > /etc/systemd/system/notify_push.service <<'EOF'
[Unit]
Description=Push daemon for Nextcloud clients
After=mysql.service redis.service
Requires=redis.service

[Service]
Environment=PORT=7867
Environment=NEXTCLOUD_URL=https://localhost
ExecStart=/var/www/nextcloud/apps/notify_push/bin/aarch64/notify_push --allow-self-signed /var/www/nextcloud/config/config.php
User=www-data
Restart=on-failure
RestartSec=20

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable notify_push

# =============================================================================
# 18. CRONTAB (pi user)
# =============================================================================
section "18. Crontab"

# Placeholder scripts — restore real content from /backup or git
for SCRIPT in update-mellon-dns.sh update-ddns.sh; do
    if [[ ! -f /home/$PI_USER/$SCRIPT ]]; then
        cat > /home/$PI_USER/$SCRIPT <<SHEOF
#!/bin/bash
# TODO: Restore $SCRIPT from backup or source
echo "$(date): $SCRIPT not yet restored" >> /tmp/${SCRIPT%.sh}.log
SHEOF
        chmod +x /home/$PI_USER/$SCRIPT
        chown "$PI_USER:$PI_USER" /home/$PI_USER/$SCRIPT
    fi
done

todo "Restore /home/pi/update-mellon-dns.sh  (DNS updater for mellon.home.kg)"
todo "Restore /home/pi/update-ddns.sh        (Dynamic DNS updater, runs every 15 min)"

sudo -u "$PI_USER" crontab - <<'EOF'
*/5 * * * * /home/pi/update-mellon-dns.sh
*/15 * * * * /home/pi/update-ddns.sh
0 23 * * 1-5 curl -s -X POST http://localhost:5000/api/balanz/backfill
0 * * * * /usr/local/bin/ncp-backup-status.sh
0 6 * * * /usr/local/bin/ncp-data-lastfile.sh
EOF

# =============================================================================
# 19. TAILSCALE
# =============================================================================
section "19. Tailscale"

systemctl enable tailscaled
systemctl start tailscaled

todo "Authenticate Tailscale (expected IP: 100.89.22.79):"
todo "  sudo tailscale up --authkey=<YOUR_AUTH_KEY>"

# =============================================================================
# 20. RETROPIE
# =============================================================================
section "20. RetroPie"

info "Cloning RetroPie-Setup and running basic install (30-60 min)..."
cd /tmp
if [[ ! -d /tmp/RetroPie-Setup ]]; then
    git clone --depth=1 https://github.com/RetroPie/RetroPie-Setup.git
fi
cd /tmp/RetroPie-Setup
# Non-interactive basic install (core + main packages)
bash retropie_setup.sh basic_install

# Ensure /home/pi/RetroPie directories exist
mkdir -p /home/$PI_USER/RetroPie/{roms,BIOS,splashscreens,retropiemenu}
chown -R "$PI_USER:$PI_USER" /home/$PI_USER/RetroPie

todo "Restore ROMs from /backup or external source to /home/pi/RetroPie/roms/"
todo "Restore BIOS files to /home/pi/RetroPie/BIOS/"
todo "Restore custom splashscreens/configs to /home/pi/RetroPie/splashscreens/"

# =============================================================================
# 21. GROUPS AND PERMISSIONS
# =============================================================================
section "21. User groups"

usermod -aG adm,dialout,cdrom,sudo,audio,video,plugdev,games,users,\
input,netdev,spi,i2c,gpio,render,docker,lpadmin "$PI_USER"

# =============================================================================
# 22. BOOT CONFIG ADDITIONS
# =============================================================================
section "22. Boot config"

grep -q "dtoverlay=pwm-2chan" /boot/firmware/config.txt || \
    echo "dtoverlay=pwm-2chan" >> /boot/firmware/config.txt

# =============================================================================
# 23. START ALL SERVICES
# =============================================================================
section "23. Starting services"

systemctl daemon-reload
systemctl start finance-tracker grocery translation-tool notify_push 2>/dev/null || \
    warn "Some services failed to start — check after restoring app repos"

# =============================================================================
# SUMMARY
# =============================================================================
section "DONE — Remaining manual steps"

echo ""
todo "1.  WiFi: nmcli dev wifi connect \"<SSID>\" password \"<PASS>\""
todo "2.  Tailscale: sudo tailscale up --authkey=<KEY>"
todo "3.  Clone finance-tracker → /home/pi/finance-tracker  (+ pip install)"
todo "4.  Clone grocery-app     → /home/pi/grocery-app       (+ npm install)"
todo "5.  Clone translation-tool → /home/pi/translation-tool (+ npm install)"
todo "6.  Restore /home/pi/translation-tool/.env"
todo "7.  Clone prode-mundial   → /home/pi/prode-mundial     (+ docker compose up -d)"
todo "8.  Restore /etc/apache2/.htpasswd-translation"
todo "9.  Restore update-mellon-dns.sh and update-ddns.sh"
todo "10. NCP DB restore: sudo ncp-restore <file> OR use web UI at https://192.168.1.6:4443"
todo "11. TLS certs: certbot --apache -d erebor.home.kg -d fulbo.home.kg -d mellon.home.kg"
todo "12. RetroPie ROMs → /home/pi/RetroPie/roms/"
todo "13. RetroPie BIOS → /home/pi/RetroPie/BIOS/"
todo "14. Reboot and verify all services:  systemctl list-units --failed"
echo ""
info "Log saved to /tmp/reinstall.log"
