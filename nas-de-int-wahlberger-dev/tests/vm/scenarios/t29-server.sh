#!/usr/bin/env bash
# BD-AC-39..46. VM only. Starts from the `stack` snapshot (restic repo `cloud` initialised).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
Q=/etc/containers/systemd/restic-server.container

# --- BD-AC-39
a=$(gs 'systemctl is-active restic-server.service; podman inspect restic-server --format "{{.Config.Cmd}} {{.Args}} {{.Config.CreateCommand}}"; podman top restic-server huser | tail -1; id -u restic-server; getent passwd restic-server; grep ^Volume= '$Q)
echo "$a" >"$OUT/ac39.txt"
huser=$(gs 'podman top restic-server huser | tail -1 | tr -d " "'); uid=$(gs 'id -u restic-server')
if grep -q '^active' <<<"$a" && grep -q -- '--private-repos' <<<"$a" && grep -q -- '--append-only' <<<"$a" && grep -q -- '--max-size 107374182400' <<<"$a" && [[ $uid -ne 0 && $uid -lt 1000 && ( $huser == "$uid" || $huser == restic-server ) ]] && grep -q '/usr/sbin/nologin' <<<"$a" && grep -Eq '^Volume=.*:Z$' <<<"$a"; then
  record "BD-AC-39" PASS "active; flags private-repos/append-only/max-size 107374182400; host user '$huser' (uid $uid, <1000, nologin); Volume ends :Z"
else record "BD-AC-39" FAIL "see $OUT/ac39.txt"; fi

# --- BD-AC-40 (SELinux parts are SKIPPED: the VM guest runs without SELinux)
m=$(gs 'stat -c "%a %U:%G" /mnt/data/restic-repos'); t=$(gs 'findmnt -T /mnt/data/restic-repos -no TARGET')
h=$(gs 'grep -c -E "^[^:]+:[$]2[yb][$]" /mnt/data/restic-repos/.htpasswd; stat -c "%a %U" /mnt/data/restic-repos/.htpasswd' | tr '\n' ' ')
pl=$(gs 'rpm -q python3$(python3 -c "import sys;print(sys.version_info.minor)")-passlib' )
leak=$(gs "grep -rlF -e $PW -e fixture-restic-repo-not-a-secret $Q /etc/systemd/system/ /etc/containers/systemd/ 2>/dev/null | wc -l")
if [[ $m == "700 restic-server:restic-server" && $t == /mnt/data && $h == "1 600 restic-server " && $pl == *passlib* && $leak == 0 ]]; then record "BD-AC-40" PASS "dir $m on $t; htpasswd 1 bcrypt hash, 600 restic-server; $pl; no password in unit/Quadlet files"
else record "BD-AC-40" FAIL "$m|$t|$h|$pl|leak=$leak"; fi
record "BD-AC-40 (SELinux labels, BD-FR-160/BD-A-11)" SKIPPED "VM guest has no SELinux (tree built by zypper --root, selinux=0); verify on the NAS"

# --- BD-AC-41
for spec in 'clients|{"restic_server_clients":[]}|restic_server_clients' 'emptypw|{"restic_server_clients":[{"username":"cloud","password":""}]}|cloud' 'repopw|{"restic_server_maintenance_repo_password":""}|restic_server_maintenance_repo_password'; do
  IFS='|' read -r n ov need <<<"$spec"
  role_only restic_server -e "$ov" >"$OUT/ac41-$n.log" 2>&1; rc=$?
  chg=$(awk '/^TASK \[/{t=$0} /^changed:/{print t}' "$OUT/ac41-$n.log" | grep -c restic_server)
  if [[ $rc -ne 0 && $chg -eq 0 ]] && grep -E 'fatal|failed' "$OUT/ac41-$n.log" | grep -q "$need"; then record "BD-AC-41 ($n)" PASS "play failed naming $need, no restic_server task changed"
  else record "BD-AC-41 ($n)" FAIL "rc=$rc changed=$chg ($OUT/ac41-$n.log)"; fi
done

# --- BD-AC-42
w=$(code -u cloud:wrong http://$VMIP:8000/cloud/config); ok=$(code -u cloud:$PW http://$VMIP:8000/cloud/config); oth=$(code -u cloud:$PW http://$VMIP:8000/other/config)
if [[ $w == 401 && $ok == 200 && ( $oth == 401 || $oth == 403 ) ]]; then record "BD-AC-42" PASS "wrong pw $w, right pw $ok, other repo $oth"; else record "BD-AC-42" FAIL "$w $ok $oth"; fi

# --- BD-AC-43
NEW=rotated-fixture-pw-not-a-secret
role_only restic_server -e "{\"restic_server_clients\":[{\"username\":\"cloud\",\"password\":\"$NEW\"}]}" >"$OUT/ac43.log" 2>&1
sleep 5; n=$(code -u cloud:$NEW http://$VMIP:8000/cloud/config); o=$(code -u cloud:$PW http://$VMIP:8000/cloud/config)
if [[ $n == 200 && $o == 401 ]]; then record "BD-AC-43" PASS "after the play (+5 s): new password $n, old $o"; else record "BD-AC-43" FAIL "new=$n old=$o"; fi
role_only restic_server >"$OUT/ac43-restore.log" 2>&1

# --- BD-AC-45
rr=$(gs 'firewall-cmd --list-rich-rules; echo ---; firewall-cmd --permanent --list-rich-rules; echo ---; firewall-cmd --list-ports; firewall-cmd --list-services')
echo "$rr" >"$OUT/ac45.txt"
cn=$(gs "podman network inspect ac45-allowed --format '{{range .Subnets}}{{.Subnet}}{{end}}'")
IMG=docker.io/curlimages/curl:8.11.1
gs "podman pull -q $IMG >/dev/null 2>&1"
vmn=$(code http://$VMIP:8000/)
ac=$(gs "podman run --rm --network ac45-allowed $IMG -s -m 5 -o /dev/null -w '%{http_code}' http://$VMIP:8000/")
df=$(gs "podman run --rm --network podman $IMG -s -m 5 -o /dev/null -w '%{http_code}' http://$VMIP:8000/")
nrules=$(grep -c 'port="8000"' <<<"$(sed -n '1,/^---/p' <<<"$rr")"); nperm=$(grep -c 'port="8000"' <<<"$(sed -n '/^---/,$p' <<<"$rr" | sed '1d')")
noports=$(grep -c '8000/tcp' <<<"$(sed -n '/--list-ports/,$p' <<<"$rr")")
hostcurl() { curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/; }   # qemu hostfwd: arrives on enp0s1 from 192.168.122.2
hin=$(hostcurl)
gs 'firewall-cmd --remove-rich-rule="rule family=ipv4 source address=192.168.122.0/24 port port=8000 protocol=tcp accept" >/dev/null'; hout=$(hostcurl)
role_only firewall >"$OUT/ac45-restore.log" 2>&1
if [[ $nrules -ge 2 && $nperm -ge 2 && $noports == 0 && $hin == 401 && $hout == 000 ]]; then record "BD-AC-45 (rich rules, external source)" PASS "one rich rule per CIDR (runtime $nrules, permanent $nperm), no 8000/tcp in ports/services; external-path client via enp0s1: allowed CIDR $hin, rule removed $hout (timeout/drop)"
else record "BD-AC-45 (rich rules, external source)" FAIL "rules=$nrules/$nperm noports=$noports in=$hin out=$hout"; fi
if [[ $ac == 401 ]]; then record "BD-AC-45 (ac45-allowed container)" PASS "401 from the ac45-allowed network ($cn) - NOTE netavark puts that subnet in firewalld zone trusted, so this does not exercise the rich rule"; else record "BD-AC-45 (ac45-allowed container)" FAIL "$ac"; fi
if [[ $df == 401 ]]; then record "BD-AC-45 (default podman network, trusted zone)" PASS "401 (BD-A-23 accepted: auth still applies)"; else record "BD-AC-45 (default podman network, trusted zone)" FAIL "got $df, expected 401"; fi

# --- BD-AC-46
gs 'rcli backup /etc/hostname >/dev/null 2>&1'; X=$(gs 'rcli snapshots --json --latest 1 | python3 -c "import sys,json;print(json.load(sys.stdin)[0][\"short_id\"])"')
gs "rcli forget $X" >"$OUT/ac46.txt" 2>&1; frc=$?
still=$(gs "rcli snapshots | grep -c $X"); chk=$(gs 'rcli check >/dev/null 2>&1; echo $?')
if [[ $frc -ne 0 && $still -ge 1 && $chk == 0 ]]; then record "BD-AC-46" PASS "forget exit $frc ($(grep -o "unexpected HTTP response ([0-9]*): [0-9]* [A-Za-z]*" $OUT/ac46.txt | head -1)), snapshot still listed, restic check 0"; else record "BD-AC-46" FAIL "frc=$frc still=$still chk=$chk"; fi
