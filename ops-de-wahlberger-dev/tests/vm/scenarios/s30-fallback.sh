#!/usr/bin/env bash
# SH-A-22 measurement: bridge fallback. Does a published port bypass the
# zone rules, and does the client source address survive? Run AFTER s20.
set -uo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

echo ">> switching to the bridge fallback (caddy + semaphore roles, --check first)"
ans ansible-playbook site.yml --tags caddy,semaphore -e vm_proxy_design=bridge_fallback --check --diff </dev/null >"$RES_DIR/fallback-check.log" 2>&1
rec FALLBACK-CHECK INFO "rc=$? $(grep -E '^ops-vm-fixture ' "$RES_DIR/fallback-check.log" | tail -1 | tr -s ' ')"
ans ansible-playbook site.yml --tags caddy,semaphore -e vm_proxy_design=bridge_fallback </dev/null >"$RES_DIR/fallback-apply.log" 2>&1
rc=$?
rec FALLBACK-APPLY INFO "rc=$rc $(grep -E '^ops-vm-fixture ' "$RES_DIR/fallback-apply.log" | tail -1 | tr -s ' ')"
[ "$rc" -eq 0 ] || grep -nE 'fatal|FAILED' "$RES_DIR/fallback-apply.log" | head -5
sleep 20

ss="$(gs 'ss -tlnp')"
echo "$ss" >"$RES_DIR/ss-fallback.txt"
rec FB-LISTENERS INFO "host listeners on :443/:80/:2019: [$(grep -E ':(443|80|2019) ' <<<"$ss" | awk '{print $4, $6}' | tr '\n' ';')] (published port is DNAT, not a host listener)"
rec FB-DNAT INFO "nft rules mentioning 443: $(gs 'nft list ruleset 2>/dev/null | grep -E "dport 443|443" | tr -s " " | head -6' | tr '\n' ';')"

in_zone="$(peer_https)"
rec FB-HTTPS-IN-ZONE INFO "https in zerotier zone: $in_zone"
gs 'firewall-cmd --zone=zerotier --remove-service=https' >/dev/null
removed="$(peer_https)"
rec FB-HTTPS-REMOVED "$([[ $removed == 000* ]] && echo 'ZONE-RULES-APPLY' || echo 'ZONE-RULES-BYPASSED')" "after --remove-service=https: $removed (primary design: blocked)"
gs 'firewall-cmd --zone=zerotier --remove-port=443/tcp' >/dev/null 2>&1
gs 'firewall-cmd --zone=zerotier --add-service=https' >/dev/null
alt="$(peer_https "$ALT_IP")"
rec FB-REMOTE-IP INFO "source $ALT_IP via fallback: $alt"
log="$(gs 'podman logs caddy 2>&1 | grep -E "\"remote_ip\"" | tail -6' | grep -o '"remote_ip":"[^"]*"' | sort | uniq -c | tr '\n' ' ')"
rec FB-CLIENT-ADDR INFO "fallback Caddy access log client addresses (peer=$PEER_IP alt=$ALT_IP): $log"
rec FB-FORWARD INFO "zone policies/forward: $(gs 'firewall-cmd --zone=zerotier --list-all; firewall-cmd --get-policies 2>&1' | tr '\n' ' ' | tr -s ' ')"
