#!/bin/bash
# =============================================================================
# BIND9 Setup Script — DNS / DoT / DoH + optional RPZ adblock
# Supports: Debian 11/12, Ubuntu 20.04/22.04/24.04
# Requires: root, open port 80 (certbot), domain pointed at this server
# =============================================================================
set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()   { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()     { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()    { echo -e "${RED}[ERR ]${NC}  $*" >&2; exit 1; }
header() { echo -e "\n${BOLD}══════════════════════════════════════\n  $*\n══════════════════════════════════════${NC}"; }

# ── Sanity checks ─────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]]          && die "Run as root (sudo $0)."
[[ -f /etc/debian_version ]] || die "Only Debian/Ubuntu is supported."

# ── 1. INPUT ─────────────────────────────────────────────────────────────────
header "Configuration"

prompt() {   # prompt "Question" "default" -> reads into $REPLY
    local q="$1" d="${2:-}"
    [[ -n "$d" ]] && q+=" [${d}]"
    read -rp "  ${q}: " REPLY
    REPLY="${REPLY:-$d}"
}

prompt "Domain for DoT/DoH (e.g. dns.example.com)" ""
[[ -z "$REPLY" ]] && die "Domain is required."
DOMAIN="$REPLY"

prompt "Upstream forwarder 1" "8.8.8.8";  FWD1="$REPLY"
prompt "Upstream forwarder 2" "1.1.1.1";  FWD2="$REPLY"

read -rp "  Enable RPZ adblock (hagezi/dns-blocklists pro list)? [y/N]: " _rpz
USE_RPZ=false; [[ "${_rpz,,}" == y* ]] && USE_RPZ=true

RPZ_TIMER="*-*-* 04:00:00"
if $USE_RPZ; then
    prompt "RPZ timer schedule (systemd OnCalendar)" "*-*-* 04:00:00"
    RPZ_TIMER="$REPLY"
fi

read -rp "  Enable statistics channel on 127.0.0.1:8053? [y/N]: " _stats
USE_STATS=false; [[ "${_stats,,}" == y* ]] && USE_STATS=true

echo
echo -e "  ${BOLD}Domain:${NC}     $DOMAIN"
echo -e "  ${BOLD}Forwarders:${NC} $FWD1 / $FWD2"
echo -e "  ${BOLD}RPZ:${NC}        $($USE_RPZ && echo "enabled ($RPZ_TIMER)" || echo disabled)"
echo -e "  ${BOLD}Stats:${NC}      $($USE_STATS && echo enabled || echo disabled)"
echo
read -rp "  Proceed? [Y/n]: " _ok
[[ "${_ok,,}" == n* ]] && exit 0

# ── 2. PACKAGES ──────────────────────────────────────────────────────────────
header "Installing packages"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y bind9 bind9utils dnsutils certbot curl util-linux
ok "Packages installed."

# ── BIND version check (DoH needs 9.18+) ─────────────────────────────────────
BIND_VER=$(named -v 2>&1 | grep -oP '(?<=BIND )\d+\.\d+' | head -1)
BIND_MAJOR=$(cut -d. -f1 <<< "$BIND_VER")
BIND_MINOR=$(cut -d. -f2 <<< "$BIND_VER")
info "Detected BIND $BIND_VER"
if [[ "$BIND_MAJOR" -lt 9 ]] || { [[ "$BIND_MAJOR" -eq 9 ]] && [[ "$BIND_MINOR" -lt 18 ]]; }; then
    warn "BIND $BIND_VER detected — DoH (port 443) requires BIND 9.18+."
    warn "DoT (port 853) will still work. Trying to install bind9 from backports..."
    # Try backports on Debian
    CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
    if [[ -n "$CODENAME" ]] && grep -qi debian /etc/os-release; then
        echo "deb http://deb.debian.org/debian ${CODENAME}-backports main" \
            > /etc/apt/sources.list.d/backports.list
        apt-get update -qq
        apt-get install -y -t "${CODENAME}-backports" bind9 bind9utils 2>/dev/null && \
            ok "Updated BIND from backports." || warn "Backports install failed; continuing with $BIND_VER."
    fi
    BIND_VER=$(named -v 2>&1 | grep -oP '(?<=BIND )\d+\.\d+' | head -1)
    BIND_MINOR=$(cut -d. -f2 <<< "$BIND_VER")
fi

DOH_ENABLED=false
[[ "$BIND_MAJOR" -ge 9 ]] && [[ "$BIND_MINOR" -ge 18 ]] && DOH_ENABLED=true
$DOH_ENABLED && ok "DoH support confirmed (BIND $BIND_VER)." \
             || warn "DoH disabled (BIND $BIND_VER < 9.18). DoT + plain DNS will work."

BIND_USER=$(id -un named 2>/dev/null || echo bind)
BIND_DIR="/etc/bind"
BIND_SSL="$BIND_DIR/ssl"

# ── 3. TLS CERTIFICATE ───────────────────────────────────────────────────────
header "Obtaining TLS certificate via certbot"

info "Domain $DOMAIN must resolve to this server and port 80 must be reachable."

# Temporarily stop any service occupying port 80
STOPPED_SVC=""
for svc in nginx apache2 lighttpd caddy; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        STOPPED_SVC="$svc"
        systemctl stop "$svc"
        warn "Temporarily stopped $svc to free port 80."
        break
    fi
done

certbot certonly \
    --standalone \
    --non-interactive \
    --agree-tos \
    --register-unsafely-without-email \
    -d "$DOMAIN" \
  || die "Certbot failed. Verify that $DOMAIN points here and port 80/tcp is open."

[[ -n "$STOPPED_SVC" ]] && { systemctl start "$STOPPED_SVC"; ok "Restarted $STOPPED_SVC."; }

CERT_SRC="/etc/letsencrypt/live/$DOMAIN"
mkdir -p "$BIND_SSL"
cp -L "$CERT_SRC/fullchain.pem" "$BIND_SSL/fullchain.pem"
cp -L "$CERT_SRC/privkey.pem"   "$BIND_SSL/privkey.pem"
chown "root:$BIND_USER" "$BIND_SSL/fullchain.pem" "$BIND_SSL/privkey.pem"
chmod 640               "$BIND_SSL/fullchain.pem" "$BIND_SSL/privkey.pem"
ok "Certificate installed to $BIND_SSL."

# Certbot renewal deploy hook
cat > /etc/letsencrypt/renewal-hooks/deploy/bind9-reload.sh <<HOOK
#!/bin/bash
# Auto-deployed by bind9-setup.sh — copies renewed certs and reloads BIND
BIND_SSL="/etc/bind/ssl"
BIND_USER="\$(id -un named 2>/dev/null || echo bind)"

cp -L "\$RENEWED_LINEAGE/fullchain.pem" "\$BIND_SSL/fullchain.pem"
cp -L "\$RENEWED_LINEAGE/privkey.pem"   "\$BIND_SSL/privkey.pem"
chown "root:\$BIND_USER" "\$BIND_SSL/fullchain.pem" "\$BIND_SSL/privkey.pem"
chmod 640                "\$BIND_SSL/fullchain.pem" "\$BIND_SSL/privkey.pem"

rndc reconfig && echo "[\$(date)] BIND reloaded after cert renewal for \$RENEWED_LINEAGE." \
  || echo "[\$(date)] WARNING: rndc reconfig failed after renewal."
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/bind9-reload.sh
ok "Certbot renewal hook installed."

# ── 4. BIND CONFIGURATION ────────────────────────────────────────────────────
header "Writing BIND9 configuration"

# Backup existing configs
for f in named.conf named.conf.options named.conf.local; do
    [[ -f "$BIND_DIR/$f" ]] && cp "$BIND_DIR/$f" "$BIND_DIR/${f}.bak.$(date +%s)"
done

# ── named.conf.options ────────────────────────────────────────────────────────
RPZ_BLOCK=""
if $USE_RPZ; then
    RPZ_BLOCK='
    response-policy {
        zone "rpz.adblock";
    };
'
fi

STATS_BLOCK=""
if $USE_STATS; then
    STATS_BLOCK='
statistics-channels {
    inet 127.0.0.1 port 8053 allow { 127.0.0.1; };
};
'
fi

DOH_LISTEN=""
if $DOH_ENABLED; then
    DOH_LISTEN='
    listen-on port 443
        tls local-tls
        http local-http-server { any; };'
fi

cat > "$BIND_DIR/named.conf.options" <<EOF
options {
    directory              "/var/cache/bind";
    managed-keys-directory "/var/lib/bind";

    // ── Recursion ────────────────────────────────────────────────────────
    recursion       yes;
    allow-recursion { any; };   // restrict to your subnets in production
    allow-query     { any; };

    // ── Forwarding ───────────────────────────────────────────────────────
    forward  only;
    forwarders {
        $FWD1;
        $FWD2;
    };

    // ── Rate limiting ────────────────────────────────────────────────────
    rate-limit {
        responses-per-second 20;
        errors-per-second     5;
        all-per-second       50;
        log-only             no;
        window               15;
    };

    max-recursion-depth   20;
    max-recursion-queries 100;

    // ── DNSSEC ───────────────────────────────────────────────────────────
    dnssec-validation auto;

    // ── Misc hardening ───────────────────────────────────────────────────
    minimal-any yes;
    version  "none";
    hostname "none";
    server-id "none";
${RPZ_BLOCK}
    // ── Cache ────────────────────────────────────────────────────────────
    max-cache-size 200m;
    max-cache-ttl  86400;
    min-cache-ttl  60;

    // ── Listeners ────────────────────────────────────────────────────────
    listen-on      port 53  { any; };
    listen-on-v6   port 53  { any; };

    listen-on port 853
        tls local-tls
        { any; };
    listen-on-v6 port 853
        tls local-tls
        { any; };
${DOH_LISTEN}
};

tls local-tls {
    cert-file "$BIND_SSL/fullchain.pem";
    key-file  "$BIND_SSL/privkey.pem";
};

http local-http-server {
    endpoints { "/dns-query"; };
};
${STATS_BLOCK}
EOF

# ── named.conf.logging ────────────────────────────────────────────────────────
mkdir -p /var/log/named
chown "$BIND_USER:$BIND_USER" /var/log/named
chmod 755 /var/log/named

cat > "$BIND_DIR/named.conf.logging" <<'EOF'
logging {
    channel "main_log" {
        file "/var/log/named/named.log" versions 3 size 20m;
        severity warning;
        print-category yes;
        print-severity yes;
        print-time     yes;
    };
    category default { "main_log"; };
    category queries { "null"; };     // disable query logging (noisy); change to "main_log" to enable
};
EOF

# ── named.conf.local ──────────────────────────────────────────────────────────
# Zone data lives in /var/lib/bind — writable by the bind user (StateDirectory=bind in systemd unit)
RPZ_DATA_DIR="/var/lib/bind"
RPZ_RAW_FILE="$RPZ_DATA_DIR/db.rpz.adblock.raw"
RPZ_TXT_FILE="$RPZ_DATA_DIR/db.rpz.adblock.txt"
RPZ_SCRIPT="/etc/bind/update-rpz.sh"

if $USE_RPZ; then
    cat > "$BIND_DIR/named.conf.local" <<'EOF'
zone "rpz.adblock" {
    type primary;
    file "/var/lib/bind/db.rpz.adblock.raw";
    masterfile-format raw;
};
EOF

    # Create a minimal valid placeholder RPZ zone so BIND can start before the first update
    ZONE_TMP=$(mktemp)
    cat > "$ZONE_TMP" <<'ZONE'
$TTL 300
@ SOA localhost. root.localhost. (
    1       ; serial
    3600    ; refresh
    600     ; retry
    86400   ; expire
    300 )   ; minimum
  NS  localhost.
ZONE

    /usr/sbin/named-compilezone -f text -F raw -q \
        -o "$RPZ_RAW_FILE" "rpz.adblock" "$ZONE_TMP" \
      || die "named-compilezone failed on placeholder zone."
    # Touch the txt file so the update script has something to compare against
    touch "$RPZ_TXT_FILE"
    rm -f "$ZONE_TMP"

    chown "$BIND_USER:$BIND_USER" "$RPZ_RAW_FILE" "$RPZ_TXT_FILE"
    chmod 644 "$RPZ_RAW_FILE" "$RPZ_TXT_FILE"
    ok "Placeholder RPZ zone created ($RPZ_RAW_FILE)."
else
    echo "// No local zones configured." > "$BIND_DIR/named.conf.local"
fi

# ── named.conf (master) ───────────────────────────────────────────────────────
cat > "$BIND_DIR/named.conf" <<'EOF'
include "/etc/bind/named.conf.options";
include "/etc/bind/named.conf.local";
include "/etc/bind/named.conf.default-zones";
include "/etc/bind/named.conf.logging";
EOF

# Validate
named-checkconf "$BIND_DIR/named.conf" \
  || die "named.conf validation failed! Check output above."
ok "BIND configuration written and validated."

# ── 5. RPZ UPDATE SCRIPT + SYSTEMD UNITS ────────────────────────────────────
if $USE_RPZ; then
    header "Deploying RPZ auto-update"

    # Script lives in /etc/bind — systemd unit's ExecStart points here
    cat > "$RPZ_SCRIPT" <<'SCRIPT'
#!/bin/bash
# RPZ adblock zone updater — hagezi/dns-blocklists pro
# Managed by systemd rpz-updater.service / rpz-updater.timer
set -euo pipefail

URL="https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/rpz/pro.txt"
ZONE_NAME="rpz.adblock"
BIND_DIR="/var/lib/bind"
TEXT_FILE="$BIND_DIR/db.rpz.adblock.txt"
RAW_FILE="$BIND_DIR/db.rpz.adblock.raw"
KEY_FILE="/etc/bind/rndc.key"

# Temp files on the same filesystem as the destination — ensures atomic mv
TEMP_FILE=$(mktemp -p "$BIND_DIR")
TEMP_RAW=$(mktemp -p "$BIND_DIR")

cleanup() {
    rm -f "$TEMP_FILE" "$TEMP_RAW"
}
trap cleanup EXIT

if ! curl -sS -f --connect-timeout 10 --max-time 180 \
        --retry 3 --retry-all-errors --retry-delay 5 \
        -o "$TEMP_FILE" "$URL"; then
    echo "Error: Download failed." >&2
    exit 1
fi

if [ ! -s "$TEMP_FILE" ]; then
    echo "Error: Downloaded file is empty." >&2
    exit 1
fi

[ -f "$TEXT_FILE" ] || touch "$TEXT_FILE"

if cmp -s "$TEMP_FILE" "$TEXT_FILE"; then
    echo "No changes detected. Skipping update."
    exit 0
fi

echo "Update detected. Compiling zone..."

if ! /usr/bin/named-compilezone -f text -F raw -q -o "$TEMP_RAW" "$ZONE_NAME" "$TEMP_FILE"; then
    echo "Error: Zone compilation failed." >&2
    exit 1
fi

chmod 644 "$TEMP_RAW" "$TEMP_FILE"

# Atomic replacement (same filesystem guaranteed by mktemp -p)
mv "$TEMP_RAW" "$RAW_FILE"
mv "$TEMP_FILE" "$TEXT_FILE"

if /usr/sbin/rndc -k "$KEY_FILE" reload "$ZONE_NAME"; then
    echo "Zone $ZONE_NAME reloaded successfully."
else
    echo "Error: rndc reload failed." >&2
    exit 1
fi
SCRIPT

    chmod 750 "$RPZ_SCRIPT"
    chown "root:$BIND_USER" "$RPZ_SCRIPT"
    ok "RPZ update script deployed to $RPZ_SCRIPT."

    # ── systemd service ──────────────────────────────────────────────────────
    cat > /etc/systemd/system/rpz-updater.service <<EOF
[Unit]
Description=Update RPZ adblock zone (hagezi/dns-blocklists pro)
After=network-online.target named.service
Wants=network-online.target

[Service]
Type=oneshot
User=$BIND_USER
Group=$BIND_USER
ExecStart=$RPZ_SCRIPT

# Hardening
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=yes
StateDirectory=bind
ReadWritePaths=/var/lib/bind /etc/bind
EOF

    # ── systemd timer ────────────────────────────────────────────────────────
    cat > /etc/systemd/system/rpz-updater.timer <<EOF
[Unit]
Description=Timer for RPZ adblock zone update

[Timer]
OnCalendar=${RPZ_TIMER}
Unit=rpz-updater.service
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now rpz-updater.timer
    ok "systemd timer enabled: rpz-updater.timer (${RPZ_TIMER}, ±5 min jitter)."
fi

# ── 6. LOGROTATE FOR NAMED ────────────────────────────────────────────────────
cat > /etc/logrotate.d/named-custom <<'LR'
/var/log/named/named.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 640 bind bind
    postrotate
        /usr/sbin/rndc reopen > /dev/null 2>&1 || true
    endscript
}
LR

# ── 7. FIREWALL ───────────────────────────────────────────────────────────────
header "Firewall"

if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 53/tcp  comment "DNS"     >/dev/null
    ufw allow 53/udp  comment "DNS"     >/dev/null
    ufw allow 853/tcp comment "DoT"     >/dev/null
    $DOH_ENABLED && ufw allow 443/tcp comment "DoH" >/dev/null
    ufw reload >/dev/null
    ok "UFW rules added (53, 853$(${DOH_ENABLED} && echo ", 443" || echo ""))."
elif command -v iptables &>/dev/null; then
    warn "UFW not active. Adding iptables rules manually."
    iptables -I INPUT -p tcp --dport 53  -j ACCEPT
    iptables -I INPUT -p udp --dport 53  -j ACCEPT
    iptables -I INPUT -p tcp --dport 853 -j ACCEPT
    $DOH_ENABLED && iptables -I INPUT -p tcp --dport 443 -j ACCEPT
    warn "iptables rules are not persistent — install iptables-persistent to save them."
else
    warn "No firewall tool found. Open ports 53/tcp+udp, 853/tcp$(${DOH_ENABLED} && echo ", 443/tcp") manually."
fi

# ── 8. ENABLE AND START NAMED ────────────────────────────────────────────────
header "Starting BIND9"

systemctl enable named
systemctl restart named

sleep 2
systemctl is-active --quiet named \
  || die "named failed to start. Run: journalctl -xe -u named"
ok "named is running."

# ── 9. INITIAL RPZ UPDATE ────────────────────────────────────────────────────
if $USE_RPZ; then
    header "Running initial RPZ update"
    info "Downloading hagezi pro blocklist via systemd service (may take a minute)..."
    if systemctl start rpz-updater.service; then
        ok "Initial RPZ update complete."
    else
        warn "Initial RPZ update failed. It will retry at the next timer trigger ($RPZ_TIMER)."
        warn "Check logs: journalctl -u rpz-updater.service"
        warn "Run manually: systemctl start rpz-updater.service"
    fi
fi

# ── 10. QUICK SMOKE TEST ─────────────────────────────────────────────────────
header "Smoke test"
if command -v dig &>/dev/null; then
    RESULT=$(dig +short +timeout=5 @127.0.0.1 example.com A 2>/dev/null || true)
    if [[ -n "$RESULT" ]]; then
        ok "dig @127.0.0.1 example.com → $RESULT"
    else
        warn "DNS query returned empty result. Check named logs: journalctl -u named"
    fi
else
    warn "dig not found — skipping smoke test."
fi

# ── SUMMARY ──────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════╗"
echo -e "║         Setup complete! ✓                ║"
echo -e "╚══════════════════════════════════════════╝${NC}"
echo
echo -e "  ${BOLD}Plain DNS${NC}   →  ${DOMAIN}:53  (TCP/UDP)"
echo -e "  ${BOLD}DNS-over-TLS${NC} →  ${DOMAIN}:853"
$DOH_ENABLED && echo -e "  ${BOLD}DNS-over-HTTPS${NC} →  https://${DOMAIN}/dns-query"
echo
echo -e "  ${BOLD}Config files:${NC}"
echo -e "    $BIND_DIR/named.conf.options"
echo -e "    $BIND_DIR/named.conf.local"
echo -e "    $BIND_DIR/named.conf.logging"
echo -e "    $BIND_SSL/  (TLS certs)"
if $USE_RPZ; then
    echo
    echo -e "  ${BOLD}RPZ:${NC}"
    echo -e "    Update script: $RPZ_SCRIPT"
    echo -e "    Timer:         ${RPZ_TIMER}  (±5 min jitter)"
    echo -e "    Logs:          journalctl -u rpz-updater.service"
fi
echo
echo -e "  ${BOLD}Useful commands:${NC}"
echo -e "    systemctl status named"
echo -e "    journalctl -u named -f"
echo -e "    named-checkconf $BIND_DIR/named.conf"
echo -e "    rndc status"
echo -e "    certbot renew --dry-run"
$USE_RPZ && echo -e "    systemctl list-timers rpz-updater.timer"
echo
