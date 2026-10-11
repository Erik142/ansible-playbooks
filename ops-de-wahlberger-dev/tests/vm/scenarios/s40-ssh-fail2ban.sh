#!/usr/bin/env bash
# SH-A-30 (sshd reload keeps a session), sshd -T facts, SH-NFR-15 / PA-4
# (fail2ban ban, public zone rich rules stay empty).
set -uo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

t="$(gs 'sshd -T 2>&1' | grep -iE '^(subsystem|allowusers|maxauthtries|passwordauthentication|permitrootlogin|authenticationmethods) ' | tr '\n' ';')"
rec SSHD-T INFO "$t"
rec SSHD-SUBSYSTEM "$(gs 'sshd -T | grep -qi "^subsystem sftp" && echo PASS || echo FAIL')" "Subsystem sftp present in effective config (vendor file seeded)"

mp0="$(gs 'systemctl show sshd -p MainPID --value')"
( vm_ssh 'echo start; sleep 40; echo alive' >"$RES_DIR/session.out" 2>&1 & )
sleep 6
gs 'systemctl reload sshd'
# New connections right after a reload: count refused attempts (sshd re-executes itself on SIGHUP).
fails=0; ok=no
for i in 1 2 3 4 5 6 7 8; do
  if vm_ssh true 2>/dev/null; then ok=yes; break; fi
  fails=$((fails + 1)); sleep 0.25
done
mp1="$(gs 'systemctl show sshd -p MainPID --value')"
sleep 40
rec SSHD-RELOAD "$([[ $(tr '\n' ' ' <"$RES_DIR/session.out") == *"alive"* && $mp0 == "$mp1" ]] && echo PASS || echo FAIL)" "session opened before reload printed 'alive' after it; sshd MainPID $mp0 -> $mp1; journal: $(gs 'journalctl -u sshd --no-pager --since "-2 min" | grep -c "Received SIGHUP"') SIGHUP line(s)"
rec SSHD-RELOAD-NEW-CONN INFO "new connection attempts at 0.25 s spacing right after the reload: $fails refused before one succeeded (succeeded=$ok)"

gs 'systemctl is-active fail2ban' >/dev/null || gs 'systemctl start fail2ban'
rec F2B-STATE INFO "$(gs 'fail2ban-client status sshd' | tr '\n' ' ' | tr -s ' ')"
rec F2B-CONFIG INFO "$(gs 'fail2ban-client get sshd maxretry; fail2ban-client get sshd actions; true' | tr '\n' ';')"
rich0="$(gs 'firewall-cmd --permanent --zone=public --list-rich-rules')"

echo ">> 6 failed logins from $PEER_IP (client namespace), 7 s apart (PerSourcePenalties)"
for i in 1 2 3 4 5 6; do
  gs "ip netns exec ztpeer ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o IdentitiesOnly=yes baduser@$ZT_IP true" >/dev/null 2>&1
  sleep 7
done
st="$(gs 'fail2ban-client status sshd' | tr '\n' ' ' | tr -s ' ')"
rec F2B-BAN "$([[ $st == *"Banned IP list:"*"$PEER_IP"* ]] && echo PASS || echo FAIL)" "after 6 failures: $st"
rec F2B-NFT INFO "nft entries for $PEER_IP: $(gs "nft list ruleset 2>/dev/null | grep -c '$PEER_IP'") ; table: $(gs 'nft list tables' | tr '\n' ';')"
perm_after="$(gs 'firewall-cmd --permanent --zone=public --list-rich-rules')"
rt_after="$(gs 'firewall-cmd --zone=public --list-rich-rules')"
after="permanent=[$perm_after] runtime=[$rt_after]"
rec F2B-RICH-RULES "$([[ -z $rich0 && -z $perm_after && -z $rt_after ]] && echo PASS || echo FAIL)" "public zone rich rules before=[$rich0], permanent/runtime after ban=[$after]"
rec F2B-OWN-SESSION INFO "fixture's own ssh (via qemu NAT, not banned): $(g 'echo ok' 2>&1)"
gs "fail2ban-client set sshd unbanip $PEER_IP" >/dev/null 2>&1
