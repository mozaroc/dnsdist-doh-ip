# dnsdist-doh-ip

Two standalone bash scripts for standing up a public DNS resolver with DNS-over-HTTPS (DoH) and DNS-over-TLS (DoT). Pick one, depending on the software you want to run.

- **`dnsdist-setup.sh`** — dnsdist as a load-balancing frontend proxying to public upstreams (Google, Cloudflare, Quad9) over DoH. TLS cert is issued for the server's **public IP address** (no domain needed), via Let's Encrypt's short-lived IP certificate profile.
- **`bind9-setup.sh`** — BIND9 as a full recursive/forwarding resolver with its own DoT/DoH listeners. Requires a **domain name** pointed at the server (cert issued via certbot for that domain).

Both scripts are idempotent-ish (safe to re-run), must run as root, and are written for Debian/Ubuntu.

## `dnsdist-setup.sh`

What it does:
1. Installs dnsdist (from the PowerDNS apt repo) + acme.sh + dependencies.
2. Detects the server's public IP via `ifconfig.me`.
3. Registers a throwaway Let's Encrypt account and issues a 6-day **IP address certificate** (RFC 8738, `shortlived` profile) using the `standalone` HTTP-01 challenge on port 80 (transient — not left open).
4. Writes `/etc/dnsdist/dnsdist.conf`:
   - DoH listener on `<public-ip>:443` (`/dns-query`)
   - DoT listener on `<public-ip>:853`
   - Backends: Google, Cloudflare, Quad9, reached via outgoing DoH with TLS cert validation (`subjectName` set per provider)
   - Packet cache (50k entries, sharded)
   - Optional ad/tracker domain blocklist (prompted at runtime), auto-updated daily via cron
   - Basic hardening: refuses `bind.`/`server.` CHAOS queries, per-IP QPS cap (50), drops over limit
5. Adds a systemd override granting `CAP_NET_BIND_SERVICE` so dnsdist can bind to 443/853 unprivileged.
6. Installs a cron job renewing the certificate every 12 hours (required since the cert is only valid 6 days); dnsdist restarts automatically only when a renewal actually happens.

One-command install:
```bash
curl -fsSL https://raw.githubusercontent.com/mozaroc/dnsdist-doh-ip/main/dnsdist-setup.sh | sudo bash
```

Or clone and run:
```bash
sudo ./dnsdist-setup.sh
```
You'll be prompted once: enable the domain blocklist? (y/N)

Endpoints after setup:
- DoH: `https://<public-ip>/dns-query`
- DoT: `tls://<public-ip>:853`

## `bind9-setup.sh`

What it does:
1. Prompts for: DNS domain (required), two upstream forwarders (default `8.8.8.8` / `1.1.1.1`), whether to enable RPZ adblocking, and whether to expose a stats channel on `127.0.0.1:8053`.
2. Installs BIND9 + certbot; checks BIND version (DoH requires 9.18+, tries Debian backports if too old — DoT/plain DNS still work either way).
3. Obtains a certbot cert for the given domain (standalone HTTP-01 on port 80; temporarily stops nginx/apache2/lighttpd/caddy if one is squatting the port), installs a certbot renewal deploy hook that copies certs and reloads BIND.
4. Writes `named.conf.options`/`named.conf.local`/`named.conf.logging`:
   - Recursive forwarding resolver (`forward only` to the two configured forwarders)
   - Listeners: plain DNS 53 (tcp/udp), DoT 853, DoH 443 (if supported)
   - Rate limiting, DNSSEC validation, `minimal-any`, version/hostname hiding
   - Optional RPZ response-policy zone (hagezi `pro` blocklist), refreshed on a systemd timer (default `04:00` daily) via `rpz-updater.service`/`.timer`
5. Sets up logrotate for BIND's log, opens firewall ports (ufw if active, else raw iptables), enables and starts `named`, runs an initial RPZ update, and does a smoke-test `dig` query.

Run:
```bash
sudo ./bind9-setup.sh
```

Endpoints after setup:
- Plain DNS: `<domain>:53`
- DoT: `<domain>:853`
- DoH (if BIND ≥ 9.18): `https://<domain>/dns-query`

## Choosing between them

| | dnsdist-setup.sh | bind9-setup.sh |
|---|---|---|
| Domain required | No (uses public IP) | Yes |
| Role | Proxy to public upstreams | Own recursive resolver |
| Blocklist source | m0zgen/bld-agregator | hagezi/dns-blocklists (pro) |
| Cert lifetime | 6 days (auto-renew every 12h) | 90 days (certbot default) |

## Requirements

- Root access
- Debian/Ubuntu host
- Port 80 reachable (briefly, for ACME/certbot HTTP-01 validation)
- For `bind9-setup.sh`: domain's DNS A/AAAA record already pointed at the server
