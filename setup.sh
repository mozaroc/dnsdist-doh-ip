#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Variables — edit before running
# ============================================================
PUBLIC_IP="$(curl -4 -fsSL https://ifconfig.me)"
_rnd() { local o; o=$(openssl rand -hex 32); echo "${o:0:$1}"; }
EMAIL="$(_rnd 10)@$(_rnd 8).com"                             # random throwaway address for ACME registration
CERT_PATH="/etc/dnsdist/tls"
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
# User choices
# ============================================================
read -rp "Do you want to enable blocking of advertising domains? [y/N]: " _block_reply
USE_BLOCKLIST=false
[[ "${_block_reply,,}" == y* ]] && USE_BLOCKLIST=true

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
# If issuance fails the script aborts — no self-signed fallback.
# ============================================================
DNSDIST_GROUP="_dnsdist"

mkdir -p "$CERT_PATH"
chown root:"$DNSDIST_GROUP" "$CERT_PATH"
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

fix_cert_permissions() {
  chown root:"$DNSDIST_GROUP" "$CERT_FILE" "$KEY_FILE" "$CERT_ONLY" 2>/dev/null || true
  chmod 640 "$CERT_FILE" "$KEY_FILE" "$CERT_ONLY" 2>/dev/null || true
}

install_acme_cert() {
  log "Installing certificate files into $CERT_PATH..."
  "$ACME" --install-cert \
    --domain         "$PUBLIC_IP" \
    --cert-file      "$CERT_ONLY" \
    --key-file       "$KEY_FILE" \
    --fullchain-file "$CERT_FILE" \
    --reloadcmd      "chown root:${DNSDIST_GROUP} ${CERT_PATH}/*.pem && chmod 640 ${CERT_PATH}/*.pem && systemctl restart dnsdist" \
    --home           "$ACME_HOME"
  fix_cert_permissions
}

if [[ ! -f "$CERT_FILE" ]] || [[ ! -f "$KEY_FILE" ]]; then
  if ! issue_letsencrypt_cert; then
    log "ERROR: Let's Encrypt certificate issuance failed. Aborting."
    exit 1
  fi
  install_acme_cert
else
  log "Certificate already exists at $CERT_FILE — skipping issuance."
  fix_cert_permissions
fi

# ============================================================
# 4. Write dnsdist configuration
# ============================================================
log "Writing /etc/dnsdist/dnsdist.conf..."

mkdir -p /etc/dnsdist

DNSDIST_KEY=$(openssl rand -base64 32)
log "Generated dnsdist control key."

# PUBLIC_IP, CERT_PATH, and DNSDIST_KEY are expanded by the shell.
cat > /etc/dnsdist/dnsdist.conf <<DNSDIST_CONF
setACL({"0.0.0.0/0", "::/0"})
controlSocket("127.0.0.1:5199")
setKey("${DNSDIST_KEY}")
-- ==========================================================================
-- dnsdist 1.8.3 — Production Public Resolver Configuration
-- ==========================================================================

-- --------------------------------------------------------------------------
-- 1. General settings
-- --------------------------------------------------------------------------
setServerPolicy(leastOutstanding)

-- --------------------------------------------------------------------------
-- 2. TLS certificates (acme.sh)
-- --------------------------------------------------------------------------
local tlsCert = "${CERT_PATH}/fullchain.pem"
local tlsKey  = "${CERT_PATH}/key.pem"

-- --------------------------------------------------------------------------
-- 3. Listeners — DoH frontend (port 443)
-- --------------------------------------------------------------------------
addDOHLocal("${PUBLIC_IP}:443", tlsCert, tlsKey, "/dns-query", {
  reusePort = true,
})

-- --------------------------------------------------------------------------
-- 4. Listeners — DoT frontend (port 853)
-- --------------------------------------------------------------------------
addTLSLocal("${PUBLIC_IP}:853", tlsCert, tlsKey, {
  reusePort = true,
  provider  = "openssl",
})

-- --------------------------------------------------------------------------
-- 5. Backends — Google, Cloudflare, Quad9 via outgoing DoH (strict IP, no SNI)
-- --------------------------------------------------------------------------
-- Connections are made strictly to the IP address.
-- validateCertificates=false because no hostname SNI is sent.

newServer({
  address              = "8.8.8.8:443",
  tls                  = "openssl",
  dohPath              = "/dns-query",
  validateCertificates = false,
  name                 = "google-1",
})

newServer({
  address              = "8.8.4.4:443",
  tls                  = "openssl",
  dohPath              = "/dns-query",
  validateCertificates = false,
  name                 = "google-2",
})

newServer({
  address              = "1.1.1.1:443",
  tls                  = "openssl",
  dohPath              = "/dns-query",
  validateCertificates = false,
  name                 = "cloudflare-1",
})

newServer({
  address              = "1.0.0.1:443",
  tls                  = "openssl",
  dohPath              = "/dns-query",
  validateCertificates = false,
  name                 = "cloudflare-2",
})

newServer({
  address              = "9.9.9.9:443",
  tls                  = "openssl",
  dohPath              = "/dns-query",
  validateCertificates = false,
  name                 = "quad9",
})

-- --------------------------------------------------------------------------
-- 6. Packet cache
-- --------------------------------------------------------------------------
local cache = newPacketCache(50000, {
  maxTTL              = 86400,
  minTTL              = 60,
  temporaryFailureTTL = 60,
  staleTTL            = 300,
  numberOfShards      = 32,
})
getPool(""):setCache(cache)

$(if $USE_BLOCKLIST; then cat <<'LUABLOCK'
-- --------------------------------------------------------------------------
-- 7. Domain blocklist — SuffixMatchNode
-- Loaded from /etc/dnsdist/blocklist.txt, updated daily by cron.
-- Evaluated before rate-limiting so blocked domains are refused immediately.
-- --------------------------------------------------------------------------
local blockList = newSuffixMatchNode()
local blFile = io.open("/etc/dnsdist/blocklist.txt", "r")
if blFile then
  for line in blFile:lines() do
    line = line:match("^%s*(.-)%s*$")       -- trim leading/trailing whitespace
    if line ~= "" and not line:match("^#") then
      local ok, err = pcall(function()
        blockList:add(newDNSName(line))
      end)
      if not ok then
        infolog("blocklist: skipping invalid entry '" .. line .. "': " .. tostring(err))
      end
    end
  end
  blFile:close()
else
  infolog("blocklist: /etc/dnsdist/blocklist.txt not found — no domains blocked yet.")
end
addAction(SuffixMatchNodeRule(blockList), RCodeAction(DNSRCode.REFUSED))
LUABLOCK
fi)

-- --------------------------------------------------------------------------
-- 8. Hardening
-- --------------------------------------------------------------------------
addAction(
  OrRule({
    QNameRule("bind."),
    QNameRule("server."),
  }),
  RCodeAction(DNSRCode.REFUSED)
)

addAction(MaxQPSIPRule(50), DropAction())

setTCPRecvTimeout(5)
setTCPSendTimeout(5)
DNSDIST_CONF

# ============================================================
# 5. Domain blocklist — initial download + update script + cron
# ============================================================
if $USE_BLOCKLIST; then
  BLOCKLIST_URL="https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/domains/pro.txt"
  BLOCKLIST_FILE="/etc/dnsdist/blocklist.txt"
  UPDATE_SCRIPT="/usr/local/bin/update-dnsdist-blocklist.sh"

  log "Downloading initial blocklist from $BLOCKLIST_URL..."
  curl -fsSL "$BLOCKLIST_URL" -o "$BLOCKLIST_FILE"
  log "Blocklist saved to $BLOCKLIST_FILE ($(wc -l < "$BLOCKLIST_FILE") lines)."

  log "Writing blocklist update script to $UPDATE_SCRIPT..."
  cat > "$UPDATE_SCRIPT" <<'UPDATESCRIPT'
#!/usr/bin/env bash
set -euo pipefail

BLOCKLIST_URL="https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/domains/pro.txt"
BLOCKLIST_FILE="/etc/dnsdist/blocklist.txt"
TMP_FILE="$(mktemp)"

curl -fsSL "$BLOCKLIST_URL" -o "$TMP_FILE"
mv "$TMP_FILE" "$BLOCKLIST_FILE"
systemctl restart dnsdist
UPDATESCRIPT
  chmod 750 "$UPDATE_SCRIPT"

  log "Installing daily blocklist cron job..."
  cat > /etc/cron.d/dnsdist-blocklist <<EOF
# Daily blocklist update — downloads fresh list and restarts dnsdist.
0 4 * * * root ${UPDATE_SCRIPT} >> /var/log/dnsdist-blocklist.log 2>&1
EOF
  chmod 644 /etc/cron.d/dnsdist-blocklist
else
  log "Domain blocking disabled — skipping blocklist download and cron."
fi

# ============================================================
# 6. systemd: allow dnsdist to bind to privileged ports 443 and 853
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
# Done
# ============================================================
log "============================================================"
log "Setup complete."
log "  DoH endpoint : https://${PUBLIC_IP}/dns-query"
log "  DoT endpoint : tls://${PUBLIC_IP}:853"
log "  Certificate  : ${CERT_PATH}"
log "  Config file  : /etc/dnsdist/dnsdist.conf"
$USE_BLOCKLIST && log "  Blocklist    : /etc/dnsdist/blocklist.txt (updated daily at 04:00)" || true
log "============================================================"
