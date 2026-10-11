#!/usr/bin/env bash
# SH-AC-04 analogue (remove/re-add https), SH-A-20 (Caddy retries until the
# address exists), listener set, client address (SH-AC-51 analogue), no outbound.
set -uo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ss="$(gs 'ss -tlnp')"
echo "$ss" >"$RES_DIR/ss-primary.txt"
csock="$(grep -c caddy <<<"$ss")"
only="$(grep caddy <<<"$ss" | awk '{print $4}' | sort | tr '\n' ' ')"
rec CADDY-LISTENERS "$([[ $only == "$ZT_IP:443 " ]] && echo PASS || echo FAIL)" "ss -tlnp caddy sockets: [$only] (count $csock); :80 present: $(grep -c ':80 ' <<<"$ss"); :2019 present: $(grep -c ':2019 ' <<<"$ss")"

code="$(peer_https)"
rec HTTPS-BASE INFO "client (198.51.100.20) https, https in zone: $code"
gs 'firewall-cmd --zone=zerotier --remove-service=https' >/dev/null
rec HTTPS-REMOVED "$([[ $(peer_https) == 000* ]] && echo PASS || echo FAIL)" "after --remove-service=https (runtime): $(peer_https)"
gs 'firewall-cmd --zone=zerotier --add-service=https' >/dev/null
rec HTTPS-READDED "$([[ $(peer_https) != 000* ]] && echo PASS || echo FAIL)" "after --add-service=https: $(peer_https)"

alt="$(peer_https "$ALT_IP")"
rec REMOTE-IP-DENY "$([[ $alt == 403* ]] && echo PASS || echo FAIL)" "source $ALT_IP (outside caddy_allowed_sources): $alt"
log="$(gs 'podman logs caddy 2>&1 | grep -E "\"remote_ip\"" | tail -3' | grep -o '"remote_ip":"[^"]*"' | sort | uniq -c | tr '\n' ' ')"
rec CLIENT-ADDR-PRIMARY "$([[ $log == *"$PEER_IP"* ]] && echo PASS || echo FAIL)" "host-network Caddy access log client addresses: $log"

echo ">> A-20: remove the interface, restart Caddy, bring the interface back"
gs 'systemctl stop fixture-zt0; systemctl restart --no-block caddy'
sleep 25
rec A20-WITHOUT-ADDR INFO "interface gone, caddy.service: $(gs 'systemctl is-active caddy; systemctl show caddy -p NRestarts -p Result' | tr '\n' ' ')"
gs 'journalctl -u caddy --no-pager -n 12' >"$RES_DIR/a20-journal.txt" 2>&1
t0=$(date +%s)
gs 'systemctl start fixture-zt0'
up=no
for ((i = 0; i < 40; i++)); do
  gs "ss -tln | grep -q '$ZT_IP:443'" && { up=yes; break; }
  sleep 2
done
rec A20-RECOVERY "$([[ $up == yes ]] && echo PASS || echo FAIL)" "Caddy listening on $ZT_IP:443 again $(( $(date +%s) - t0 )) s after the interface appeared (RestartSec=10); NRestarts=$(gs 'systemctl show caddy -p NRestarts --value')"
rec A20-ZONE-LATE INFO "zone of the re-created zt0 without any reload: [$(gs 'firewall-cmd --get-zone-of-interface=zt0 2>&1')]; client https: $(peer_https)"

egress="$(gs 'podman logs caddy 2>&1 | grep -ciE "acme|letsencrypt|cloudflare|obtain"')"
rec NO-OUTBOUND INFO "caddy log lines mentioning acme/letsencrypt/cloudflare/obtain: $egress (tls internal, hosts blackholed; full lines in results dir)"
gs 'podman logs caddy 2>&1 | grep -iE "acme|letsencrypt|cloudflare|obtain|issuer" | cut -c1-240' >"$RES_DIR/caddy-tls-lines.txt" 2>&1
