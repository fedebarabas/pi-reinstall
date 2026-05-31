# Pi Server Reinstall Playbook

Disaster recovery for `nextcloudpi` (192.168.1.6) after SD card failure.  
The SD card holds the OS root. The external drives survive and are assumed intact:

| Drive | Mount | Contents |
|-------|-------|----------|
| sda1 (UUID `d15012d9-...`) | `/storage` | Nextcloud data, media files |
| sdb1 (UUID `51d71388-...`) | `/backup`  | NCP automated backups |

## Scripts

| Script | What it installs |
|--------|-----------------|
| `reinstall-full.sh` | Everything — Nextcloud, all apps, Docker, Samba, RetroPie, etc. |
| `reinstall-no-retropie.sh` | Same, minus RetroPie and its build dependencies |

Both scripts are idempotent for config writes (they overwrite files) and safe to re-run if they stop partway through.

---

## Step 0 — Flash a new SD card

1. Download **Raspberry Pi OS Lite, 64-bit (Bookworm)** from https://www.raspberrypi.com/software/
2. Flash it with Raspberry Pi Imager or `dd`.
3. Before booting, use Imager's **Advanced settings** (⚙ gear) to:
   - Set hostname: `nextcloudpi`
   - Enable SSH with public-key auth (paste your `~/.ssh/id_rsa.pub`)
   - (Optional) pre-configure WiFi for initial access
4. Insert card, connect eth0 to the router, power on.
5. SSH in: `ssh pi@<temporary-ip>` (find it via router DHCP table or `arp -na`).

---

## Step 1 — Connect the external drives

Physically attach sda and sdb via USB before running the script. Verify:

```bash
lsblk -f
# You should see sda1 and sdb1 with their labels (lanubenew / lanube)
```

---

## Step 2 — Run the reinstall script

```bash
# Copy the script to the Pi (run this on your Mac):
scp reinstall-full.sh pi@<ip>:/home/pi/
# — or —
scp reinstall-no-retropie.sh pi@<ip>:/home/pi/

# SSH in and run as root:
ssh pi@<ip>
sudo bash reinstall-full.sh 2>&1 | tee /tmp/reinstall.log
```

The script will:
- Set hostname, locale (en_GB.UTF-8), timezone (Europe/Stockholm), keyboard (US)
- Configure eth0 as static 192.168.1.6
- Add sda1 and sdb1 to `/etc/fstab` and mount them
- Install all packages (~200 packages, takes 5–10 min)
- Run the **NextcloudPi installer** (~15–30 min — Nextcloud + MariaDB + PHP 8.3 + Redis + Apache)
- Write `config.php` with the original instance secrets
- Configure all 5 Apache virtual hosts
- Configure Dnsmasq, Samba, MiniDLNA, Fail2ban
- Install Docker and start Transmission + Homepage containers
- Create systemd units for finance-tracker, grocery, translation-tool, notify_push
- Install the pi user crontab
- Install and enable Tailscale daemon
- **(Full version only)** Clone and run the RetroPie Setup Script (~30–60 min)

Watch for `[TODO]` lines in the output — those are steps the script cannot automate.

---

## Step 3 — Restore the Nextcloud database

The Nextcloud files live on `/storage` (intact) but the MariaDB database was on the SD card and is gone. Restore it from the NCP backup on `/backup`.

**Option A — NCP web UI (easiest)**

1. Open `https://192.168.1.6:4443` in a browser (accept the self-signed cert for now).
2. Log in with user `ncp` and your NCP admin password.
3. Go to **Backups → nc-restore** and select the latest `.tar` or `.zip` from `/backup`.
4. Click Restore. This restores the database and re-links the data directory.

**Option B — Command line**

```bash
# Find latest backup
ls -lt /backup/*.tar /backup/*.zip 2>/dev/null | head -5

# Restore (replace filename)
sudo ncp-restore /backup/nextcloudpi_backup_YYYYMMDD.tar
```

**After restore, verify Nextcloud is healthy:**

```bash
sudo -u www-data php /var/www/nextcloud/occ status
sudo -u www-data php /var/www/nextcloud/occ maintenance:repair
sudo -u www-data php /var/www/nextcloud/occ files:scan --all
```

---

## Step 4 — Issue TLS certificates

DNS must be pointing at the server before running certbot. Verify:

```bash
dig erebor.home.kg    # should resolve to 192.168.1.6 or your public IP
dig fulbo.home.kg
dig mellon.home.kg
```

Then request certificates:

```bash
sudo certbot --apache \
  -d erebor.home.kg \
  -d fulbo.home.kg \
  -d mellon.home.kg
```

Certbot will also auto-configure the Apache SSL vhosts. The NCP vhost (`:4443`) reuses the `erebor.home.kg` cert — it updates automatically once that cert exists.

---

## Step 5 — Connect Tailscale

```bash
# Replace <AUTH_KEY> with a key from https://login.tailscale.com/admin/settings/keys
sudo tailscale up --authkey=<AUTH_KEY>

# Verify (expected IP: 100.89.22.79 — may differ on re-registration)
tailscale ip
tailscale status
```

---

## Step 6 — Set WiFi credentials

The wlan0 interface is managed by NetworkManager using the `RetroPie-WiFi` profile.

```bash
# List available networks
nmcli dev wifi list

# Connect (creates/updates the profile)
sudo nmcli dev wifi connect "YOUR_SSID" password "YOUR_WIFI_PASSWORD"

# Verify
ip addr show wlan0
```

---

## Step 7 — Restore the app repositories

Each custom app needs its code cloned and dependencies installed.

### 7a. Finance Tracker (Python, port 5000)

```bash
# Clone (replace URL if private repo — check your GitHub)
git clone <FINANCE_TRACKER_REPO_URL> /home/pi/finance-tracker
cd /home/pi/finance-tracker
python3 -m venv venv
venv/bin/pip install -r requirements.txt
sudo systemctl start finance-tracker
sudo systemctl status finance-tracker
```

### 7b. Grocery App (Node.js, port 4000)

The repo is public. The script clones it automatically, but if you need to do it manually:

```bash
git clone git@github.com:fedebarabas/grocery-app.git /home/pi/grocery-app
cd /home/pi/grocery-app
npm install
```

**Important:** `data/groceries.json` is gitignored — it holds the live shopping list and purchase history and must be restored separately. The script looks for it at `/backup/grocery/groceries.json`. If you have a copy elsewhere:

```bash
mkdir -p /home/pi/grocery-app/data
cp /your/backup/groceries.json /home/pi/grocery-app/data/groceries.json
```

If no backup exists the app starts with an empty list (no data loss beyond the list itself — the app rebuilds its history from use).

```bash
sudo systemctl start grocery
sudo systemctl status grocery
# App is available at http://192.168.1.6:4000
```

### 7c. Translation Tool (Node.js, port 3001)

```bash
git clone <TRANSLATION_TOOL_REPO_URL> /home/pi/translation-tool
cd /home/pi/translation-tool
npm install
```

Restore the `.env` file (contains Google OAuth credentials and API keys):

```bash
# Either copy from a secure backup:
cp /backup/secrets/translation-tool.env /home/pi/translation-tool/.env

# Or recreate it manually — the file needs at minimum:
#   GOOGLE_CLIENT_ID=...
#   GOOGLE_CLIENT_SECRET=...
#   SESSION_SECRET=...
#   PORT=3001
nano /home/pi/translation-tool/.env
```

Then start:

```bash
sudo systemctl start translation-tool
sudo systemctl status translation-tool
```

### 7d. Prode Mundial (Docker, port 1986 → fulbo.home.kg)

```bash
git clone <PRODE_MUNDIAL_REPO_URL> /home/pi/prode-mundial
cd /home/pi/prode-mundial

# Build and start (the compose file is already there from git)
docker compose up -d --build

# Verify container is up on port 1986
docker ps | grep prode
curl -s http://localhost:1986/ | head -5
```

---

## Step 8 — Restore the translation-tool htpasswd

The `mellon.home.kg` site is protected by HTTP Basic Auth:

```bash
# Create new password file (prompts for password)
sudo htpasswd -c /etc/apache2/.htpasswd-translation <USERNAME>

# Reload Apache
sudo systemctl reload apache2
```

---

## Step 9 — Restore custom DNS/DDNS scripts

Two cron scripts run every 5 and 15 minutes from `/home/pi/`:

| Script | Purpose | Frequency |
|--------|---------|-----------|
| `update-mellon-dns.sh` | Updates DNS record for `mellon.home.kg` | Every 5 min |
| `update-ddns.sh` | Dynamic DNS updater (public IP) | Every 15 min |

Restore from backup or recreate from source:

```bash
# If kept in a git repo:
cp /path/to/backup/update-mellon-dns.sh /home/pi/update-mellon-dns.sh
cp /path/to/backup/update-ddns.sh /home/pi/update-ddns.sh
chmod +x /home/pi/update-mellon-dns.sh /home/pi/update-ddns.sh

# Verify crontab is in place:
crontab -l
```

---

## Step 10 — Restore RetroPie data (full script only)

The RetroPie emulators are reinstalled by the script but ROMs, BIOS files, and configs were on the SD card and are lost. Restore from `/backup` or an external source:

```bash
# ROMs
rsync -av /backup/retropie/roms/ /home/pi/RetroPie/roms/

# BIOS files
rsync -av /backup/retropie/BIOS/ /home/pi/RetroPie/BIOS/

# Saved games / configs
rsync -av /backup/retropie/configs/ /opt/retropie/configs/

# Splash screens
rsync -av /backup/retropie/splashscreens/ /home/pi/RetroPie/splashscreens/
```

---

## Step 11 — Final verification

```bash
# Check for any failed units
systemctl list-units --failed

# Check all expected services are active
for svc in apache2 mariadb redis-server php8.3-fpm docker tailscaled \
           finance-tracker grocery translation-tool notify_push \
           minidlna samba dnsmasq fail2ban; do
    echo -n "$svc: "
    systemctl is-active "$svc"
done

# Check Apache virtual hosts respond
curl -sk https://erebor.home.kg/ | grep -o '<title>.*</title>' || echo "Nextcloud OK"
curl -sk https://fulbo.home.kg/  | head -3
curl -sk https://mellon.home.kg/ -u user:pass | head -3

# Check Docker containers
docker ps

# Check finance tracker
curl -s http://localhost:5000/ | head -3

# Check grocery app
curl -s http://localhost:4000/api/ping
# → {"ok":true}
```

---

## Service map

```
Port  Protocol  Service
────  ────────  ───────────────────────────────────────────────────
80    HTTP      Apache — redirect to HTTPS
443   HTTPS     Apache — Nextcloud (erebor.home.kg)
                         Prode app (fulbo.home.kg)
                         Translation tool (mellon.home.kg)
3000  HTTP      Homepage dashboard (Docker)
3001  HTTP      Translation tool Node.js (internal, proxied)
4000  HTTP      Grocery App (Node.js, direct access)
4443  HTTPS     NCP web admin UI
5000  HTTP      Finance Tracker (Gunicorn)
7867  HTTP      Nextcloud notify_push (internal)
8099  HTTP      Status page
8200  HTTP      MiniDLNA / DLNA
9091  HTTP      Transmission web UI (via Docker)
1986  HTTP      Prode Mundial app (internal, proxied as fulbo.home.kg)
```

---

## Architecture overview

```
Internet / LAN
      │
      ▼
  Apache 2  (80, 443, 4443, 8099)
  ├── erebor.home.kg:443  ──► /var/www/nextcloud  (PHP-FPM 8.3)
  │                               └─ data: /storage/nextcloud/data
  │                               └─ DB:   MariaDB  ←→  Redis (cache)
  │                               └─ push: notify_push :7867
  ├── fulbo.home.kg:443   ──► localhost:1986  (Docker: prode-mundial)
  ├── mellon.home.kg:443  ──► localhost:3001  (systemd: translation-tool)
  ├── *:4443              ──► /var/www/ncp-web  (NCP admin)
  └── *:8099              ──► /var/www/html  (status)

  systemd services (user-space)
  ├── finance-tracker   :5000  /home/pi/finance-tracker  (Python/Gunicorn)
  ├── grocery           ----   /home/pi/grocery-app       (Node.js)
  └── translation-tool  :3001  /home/pi/translation-tool  (Node.js)

  Docker (Compose at /home/pi/docker-compose.yml)
  ├── transmission-openvpn  :9091  downloads to /storage/media/
  └── homepage              :3000  reads /storage, /backup (read-only)

  Docker (Compose at /home/pi/prode-mundial/docker-compose.yml)
  ├── prode-mundial-prode-1   :1986 (public)
  ├── prode-mundial-sync-1    (internal)
  └── prode-mundial-notify-1  (internal)

  External drives
  ├── /storage  (sda1, 1.8TB)  — Nextcloud data, media, downloads
  └── /backup   (sdb1, 1.8TB)  — NCP backups, rsync snapshots
```
