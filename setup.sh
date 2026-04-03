#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Variables — edit before running
# ============================================================
PUBLIC_IP="$(curl -4 -fsSL https://ifconfig.me)"
EMAIL="admin@example.com"                                    # CHANGE: ACME account email
CERT_PATH="/etc/dnsdist/certs"
REPO_URL="https://github.com/YOUR_USERNAME/YOUR_REPO.git"   # CHANGE: git remote URL
WEB_PORT=80                                                  # port used transiently for ACME http-01 challenge

# ============================================================
# Helpers
# ============================================================
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

[[ $EUID -eq 0 ]] || { echo "ERROR: must run as root."; exit 1; }

# Validate IP was resolved
[[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "ERROR: Could not determine public IP (got: '$PUBLIC_IP'). Aborting."
  exit 1
}
log "Public IP: $PUBLIC_IP"

# ============================================================
# 1. Install system dependencies
# ============================================================
log "Updating package index and installing dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# Add PowerDNS repository for dnsdist on Ubuntu 24.04 (Noble)
if [[ ! -f /etc/apt/sources.list.d/pdns.list ]]; then
  log "Adding PowerDNS repository for Ubuntu 24.04 (Noble)..."
  curl -fsSL https://repo.powerdns.com/FD380FBB-pub.asc \
    | gpg --dearmor -o /usr/share/keyrings/powerdns-archive-keyring.gpg

  cat > /etc/apt/sources.list.d/pdns.list <<'EOF'
deb [signed-by=/usr/share/keyrings/powerdns-archive-keyring.gpg] http://repo.powerdns.com/ubuntu noble-dnsdist-19 main
EOF

  cat > /etc/apt/preferences.d/pdns <<'EOF'
Package: dnsdist
Pin: origin repo.powerdns.com
Pin-Priority: 600
EOF
  apt-get update -qq
fi

apt-get install -y --no-install-recommends \
  dnsdist \
  curl \
  git \
  socat \
  openssl \
  cron

# ============================================================
# 2. Install acme.sh
# ============================================================
ACME_HOME="/root/.acme.sh"
ACME="${ACME_HOME}/acme.sh"

if [[ ! -f "$ACME" ]]; then
  log "Installing acme.sh..."
  # Run the installer without extra flags; --home and --accountemail are
  # not install-time flags — they are passed to acme.sh commands directly.
  export ACME_HOME="$ACME_HOME"
  curl -fsSL https://get.acme.sh | bash
else
  log "acme.sh already installed, skipping install."
fi

# Register (or re-register) the Let's Encrypt account, then force-update
# the contact email. --register-account --force is idempotent: it creates
# the account if absent, or refreshes it if it already exists.
# --update-account is then called to ensure the email is applied even when
# the account was pre-existing from a prior run with a different email.
log "Registering Let's Encrypt account and setting email to $EMAIL..."
"$ACME" --register-account -m "$EMAIL" --server letsencrypt --force --home "$ACME_HOME"
log "Force-updating Let's Encrypt account email to $EMAIL..."
"$ACME" --update-account -m "$EMAIL" --server letsencrypt --home "$ACME_HOME"

# ============================================================
# 3. Obtain TLS certificate for the server's public IP address
#
# Let's Encrypt supports IP address certificates via its "shortlived"
# certificate profile (6-day validity, RFC 8738 ip identifier type).
# acme.sh uses http-01 standalone challenge — port $WEB_PORT is bound
# transiently for validation only and is not left open afterwards.
#
# Fallback: if issuance fails a self-signed certificate is generated
# so dnsdist can still start. Replace it as soon as possible.
# ============================================================
mkdir -p "$CERT_PATH"
chmod 750 "$CERT_PATH"

CERT_FILE="${CERT_PATH}/fullchain.pem"
KEY_FILE="${CERT_PATH}/key.pem"
CERT_ONLY="${CERT_PATH}/cert.pem"

issue_letsencrypt_cert() {
  log "Setting Let's Encrypt as default CA..."
  "$ACME" --set-default-ca --server letsencrypt --force --home "$ACME_HOME"

  log "Requesting Let's Encrypt short-lived certificate for IP $PUBLIC_IP..."
  "$ACME" --issue \
    --standalone \
    --domain               "$PUBLIC_IP" \
    --server               letsencrypt \
    --certificate-profile  shortlived \
    --days                 6 \
    --httpport             "$WEB_PORT" \
    --home                 "$ACME_HOME" \
    --force
}

install_acme_cert() {
  log "Installing certificate files into $CERT_PATH..."
  "$ACME" --install-cert \
    --domain        "$PUBLIC_IP" \
    --cert-file     "$CERT_ONLY" \
    --key-file      "$KEY_FILE" \
    --fullchain-file "$CERT_FILE" \
    --reloadcmd     "systemctl restart dnsdist" \
    --home          "$ACME_HOME"
}

generate_self_signed() {
  log "WARNING: Falling back to self-signed certificate for IP $PUBLIC_IP."
  log "         Replace with a valid certificate when possible."
  openssl req -x509 -nodes \
    -newkey rsa:2048 \
    -keyout "$KEY_FILE" \
    -out    "$CERT_FILE" \
    -days   90 \
    -subj   "/CN=${PUBLIC_IP}" \
    -addext "subjectAltName=IP:${PUBLIC_IP}"
  cp "$CERT_FILE" "$CERT_ONLY"
}

if [[ ! -f "$CERT_FILE" ]] || [[ ! -f "$KEY_FILE" ]]; then
  if issue_letsencrypt_cert; then
    install_acme_cert
  else
    log "Let's Encrypt issuance failed. Generating self-signed fallback certificate."
    generate_self_signed
  fi
else
  log "Certificate already exists at $CERT_FILE — skipping issuance."
fi

chmod 640 "$CERT_FILE" "$KEY_FILE" "$CERT_ONLY" 2>/dev/null || true

# ============================================================
# 4. Write dnsdist configuration
# ============================================================
log "Writing /etc/dnsdist/dnsdist.conf..."

mkdir -p /etc/dnsdist

cat > /etc/dnsdist/dnsdist.conf <<'DNSDIST_CONF'
-- ============================================================
-- dnsdist configuration
-- DNS-over-HTTPS (DoH), port 443, with DNS cache
-- ============================================================

-- ============================================================
-- BACKEND DNS SERVERS — PLACEHOLDERS, REPLACE BEFORE USE
-- 192.0.2.x is an RFC 5737 documentation range (not routable).
-- Replace both entries with the IPs of your actual resolvers.
-- Do not leave these placeholder values in a production setup.
-- ============================================================
newServer({address="192.0.2.1:53", name="placeholder-backend-1"})   -- REPLACE: 192.0.2.1 is a dummy placeholder
newServer({address="192.0.2.2:53", name="placeholder-backend-2"})   -- REPLACE: 192.0.2.2 is a dummy placeholder

-- ============================================================
-- DoH listener — binds ONLY on port 443
-- ============================================================
addDOHLocal(
  "0.0.0.0:443",
  "/etc/dnsdist/certs/fullchain.pem",
  "/etc/dnsdist/certs/key.pem",
  "/dns-query",
  {
    reusePort       = true,
    tcpFastOpenSize = 0,
    minTLSVersion   = "tls1.2",
  }
)

-- ============================================================
-- DNS packet cache (10 000 entries)
-- ============================================================
local pc = newPacketCache(10000, {
  maxTTL              = 86400,
  minTTL              = 0,
  temporaryFailureTTL = 60,
  staleTTL            = 60,
  dontAge             = false,
})
getPool(""):setCache(pc)

-- ============================================================
-- Connection / security limits
-- ============================================================
setMaxUDPOutstanding(65535)
setMaxTCPConnectionsPerClient(100)
DNSDIST_CONF

# ============================================================
# 5. systemd: allow dnsdist to bind to privileged port 443
# ============================================================
log "Configuring systemd override for dnsdist..."

OVERRIDE_DIR="/etc/systemd/system/dnsdist.service.d"
mkdir -p "$OVERRIDE_DIR"

cat > "${OVERRIDE_DIR}/capabilities.conf" <<'EOF'
[Service]
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
EOF

systemctl daemon-reload
systemctl enable dnsdist
systemctl restart dnsdist
log "dnsdist started."

# ============================================================
# 6. Certificate renewal cron job (every 12 hours)
#
# Let's Encrypt shortlived certs are valid for 6 days. acme.sh
# renews when less than 1/3 of validity remains (~2 days), so
# running every 12 hours ensures renewal is never missed.
# dnsdist is restarted ONLY when a renewal actually occurs,
# via the --reloadcmd registered in install_acme_cert above.
# ============================================================
log "Installing certificate renewal cron job (every 12 hours)..."

cat > /etc/cron.d/acme-renewal <<CRONEOF
# Certificate renewal every 12 hours (required for 6-day shortlived certs).
# dnsdist is restarted by acme.sh's --reloadcmd ONLY when the
# certificate is actually renewed (not on every cron run).
0 */12 * * * root ${ACME} --cron --home ${ACME_HOME} >> /var/log/acme-renewal.log 2>&1
CRONEOF
chmod 644 /etc/cron.d/acme-renewal

# ============================================================
# 7. Git: commit all generated configuration files
# ============================================================
log "Initialising git repository and committing generated files..."

GIT_ROOT="/etc/dnsdist"
cd "$GIT_ROOT"

# Exclude the private key from version control
cat > .gitignore <<'EOF'
certs/key.pem
EOF

if [[ ! -d .git ]]; then
  git init
  git checkout -b main 2>/dev/null || git branch -M main
fi

git config user.email "$EMAIL"     2>/dev/null || true
git config user.name  "dnsdist-setup" 2>/dev/null || true

git add .gitignore dnsdist.conf
# Stage public cert files if they exist; ignore failure if they are absent
git add certs/fullchain.pem certs/cert.pem 2>/dev/null || true

if git diff --cached --quiet; then
  log "Git: nothing new to commit."
else
  git commit -m "initial dnsdist + doh setup"
  log "Git: committed changes."
fi

# Push to remote if REPO_URL has been customised
if [[ "$REPO_URL" == *"YOUR_USERNAME"* ]]; then
  log "WARNING: REPO_URL is still a placeholder — skipping git push."
  log "         Set REPO_URL at the top of this script, then run:"
  log "           cd ${GIT_ROOT} && git remote add origin <url> && git push -u origin main"
else
  if git remote get-url origin &>/dev/null; then
    git remote set-url origin "$REPO_URL"
  else
    git remote add origin "$REPO_URL"
  fi
  git push -u origin main
  log "Git: pushed to $REPO_URL"
fi

# ============================================================
# Done
# ============================================================
log "============================================================"
log "Setup complete."
log "  DoH endpoint : https://${PUBLIC_IP}/dns-query"
log "  Certificate  : ${CERT_PATH}"
log "  Config file  : /etc/dnsdist/dnsdist.conf"
log ""
log "ACTION REQUIRED: open /etc/dnsdist/dnsdist.conf and replace"
log "  the two placeholder backend lines (192.0.2.1 and 192.0.2.2)"
log "  with the IPs of your actual DNS resolvers, then:"
log "    systemctl restart dnsdist"
log "============================================================"
