#!/usr/bin/env bash
# BD-AC-47..52, BD-AC-54 (prune guard, maintenance run). VM only; run from the `stack` snapshot.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
M=restic-server-maintenance.service
R=/mnt/data/restic-repos/cloud
res() { gs "systemctl show -p Result --value $1"; }
count() { gs "rcli snapshots --json | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))'"; }
ids() { gs "rcli snapshots --json | python3 -c 'import sys,json;print(\" \".join(s[\"id\"] for s in json.load(sys.stdin)))'"; }
quiet_timers
gs 'zypper -n in --no-recommends rsync >/dev/null 2>&1; for i in 1 2 3; do rcli backup /etc/hostname >/dev/null 2>&1; sleep 1; done'

# --- BD-AC-47
for spec in "plus2d|+2 days" "minus3d|-3 days"; do
  n=${spec%%|*}; t=$(gs "date -d '${spec#*|}' '+%Y-%m-%d %H:%M:%S'")
  gs "rcli backup --time '$t' /etc/hostname >/dev/null 2>&1"
  F=$(gs "rcli snapshots --json | python3 -c 'import sys,json;l=json.load(sys.stdin);l.sort(key=lambda s:s[\"time\"]);print((l[-1] if \"+\" in \"${spec#*|}\" else min(l,key=lambda s:s[\"time\"]))[\"id\"])'")
  before=$(count); T=$(now)
  gs "systemctl start $M"; r=$(res $M); sleep 5; al=$(alert_since $M "$T"); after=$(count)
  jl=$(gs "journalctl -u $M --since '$T' --no-pager -o cat | grep -c ${F:0:8}")
  if [[ $r == exit-code && $al -ge 1 && $before == "$after" && $jl -ge 1 ]]; then record "BD-AC-47 ($n)" PASS "forged time '$t': unit failed, alert ($al), snapshots $before->$after, journal lists ${F:0:8}"
  else record "BD-AC-47 ($n)" FAIL "r=$r al=$al before=$before after=$after jl=$jl F=$F"; fi
  gs "sudo -u restic-server rm -f $R/snapshots/$F"
done

# --- BD-AC-48
gs 'for i in 1 2; do rcli backup /etc/hostname >/dev/null 2>&1; sleep 1; done'
T=$(now); gs "systemctl start $M"; r=$(res $M)
j=$(gs "journalctl -u $M --since '$T' --no-pager -o cat")
echo "$j" >"$OUT/ac48.txt"
own=$(gs "find $R ! -user restic-server | wc -l"); nb=$(gs 'rcli backup /etc/hostname >/dev/null 2>&1; echo $?'); rq=$(gs 'rpm -q restic >/dev/null; echo $?')
if [[ $r == success && $rq == 0 && $own == 0 && $nb == 0 ]] && grep -Eqi 'retention policy: keep 7 daily, 4 weekly, 6 monthly' <<<"$j" && grep -qi 'no errors were found' <<<"$j" && grep -qi 'prune' <<<"$j"; then record "BD-AC-48" PASS "Result=success; policy line keep 7 daily/4 weekly/6 monthly, prune output, 'no errors were found'; no file outside restic-server ownership; next backup exit 0"
else record "BD-AC-48" FAIL "r=$r own=$own nb=$nb (see $OUT/ac48.txt)"; fi

# --- BD-AC-52
pw=$(gs "systemctl cat $M | grep -cF fixture-restic-repo-not-a-secret"); em=$(gs 'stat -c "%a %U:%G" /etc/restic-server-maintenance.env')
if [[ $pw == 0 && $em == "600 root:root" ]]; then record "BD-AC-52" PASS "0 matches of the repo password in systemctl cat; env file $em"; else record "BD-AC-52" FAIL "$pw $em"; fi

# --- BD-AC-50
gs 'cp -a /etc/restic-server-maintenance.env /root/maint.env.orig; sed -i "s/^RESTIC_PASSWORD=.*/RESTIC_PASSWORD=wrong-by-hand/" /etc/restic-server-maintenance.env'
T=$(now); gs "systemctl start $M"; r=$(res $M); sleep 5; al=$(alert_since $M "$T")
role_only restic_server >"$OUT/ac50.log" 2>&1
chg=$(awk '/^TASK \[/{t=$0} /^changed:/{print t}' "$OUT/ac50.log" | grep -ci 'maintenance\|env'); same=$(gs 'cmp /etc/restic-server-maintenance.env /root/maint.env.orig && echo same')
if [[ $r == exit-code && $al -ge 1 && $chg -ge 1 && $same == same ]]; then record "BD-AC-50" PASS "wrong password: unit failed, alert ($al); role run restored the file (changed tasks: $chg)"; else record "BD-AC-50" FAIL "r=$r al=$al chg=$chg same=$same"; fi

# --- BD-AC-51
gs "mv $R $R.x"; T=$(now); gs "systemctl start $M"; r=$(res $M); ex=$(gs "test -e $R/config && echo yes || echo no"); gs "mv $R.x $R"
if [[ $r == exit-code && $ex == no ]]; then record "BD-AC-51" PASS "repository renamed away: unit failed, $R/config not created"; else record "BD-AC-51" FAIL "r=$r ex=$ex"; fi

# --- BD-AC-54 (before 49: needs 5 snapshots; leaves the repo as restored)
gs "rcli snapshots --json | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))' >/tmp/n0"; 
while [[ $(count) -lt 5 ]]; do gs 'rcli backup /etc/hostname >/dev/null 2>&1; sleep 1'; done
n5=$(count); snapN=$(gs 'snapper -c data create --print-number --description ac54')
gs "sudo -u restic-server env RESTIC_REPOSITORY=$R RESTIC_PASSWORD=fixture-restic-repo-not-a-secret restic --no-cache forget --keep-last 1 --prune >/tmp/ac54-prune.log 2>&1"
nafterprune=$(gs "sudo -u restic-server env RESTIC_REPOSITORY=$R RESTIC_PASSWORD=fixture-restic-repo-not-a-secret restic --no-cache snapshots --json | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))'")
gs "systemctl stop restic-server.service restic-server-maintenance.timer; rsync -a /mnt/data/.snapshots/$snapN/snapshot/restic-repos/cloud/ $R/; systemctl start restic-server.service restic-server-maintenance.timer"
chk=$(gs "sudo -u restic-server env RESTIC_REPOSITORY=$R RESTIC_PASSWORD=fixture-restic-repo-not-a-secret restic --no-cache check --read-data >/tmp/ac54-check.log 2>&1; echo \$?")
nrest=$(count); nb=$(gs 'rcli backup /etc/hostname >/dev/null 2>&1; echo $?')
gs "systemctl start $M"; r=$(res $M)
if [[ $chk == 0 && $nrest == "$n5" && $nb == 0 && $r == success && $nafterprune == 1 ]]; then record "BD-AC-54" PASS "after wrong prune ($n5 -> $nafterprune snapshot) rsync -a from snapper snapshot $snapN (no --delete): check --read-data 0, $nrest snapshots, next backup 0, maintenance Result=success"
else record "BD-AC-54" FAIL "n5=$n5 afterprune=$nafterprune chk=$chk nrest=$nrest nb=$nb r=$r (see /tmp/ac54-check.log in guest)"; fi

# --- BD-AC-49 (lock held by `restic mount` as restic-server, as the spec says; a client backup
# would add a snapshot and trip the TOCTOU guard instead)
gs 'zypper -n in --no-recommends fuse3 >/dev/null 2>&1; ln -sf $(command -v fusermount3) /usr/bin/fusermount; install -d -o restic-server -g restic-server /tmp/m'
gs "(setsid nohup sudo -u restic-server env RESTIC_REPOSITORY=$R RESTIC_PASSWORD=fixture-restic-repo-not-a-secret restic --no-cache mount /tmp/m >/tmp/mount.log 2>&1 </dev/null &)"; sleep 5
T=$(now); gs "systemctl start --no-block $M"; sleep 115; st1=$(gs "systemctl is-active $M")
gs 'pkill -f "restic --no-cache mount"; sleep 1; umount /tmp/m 2>/dev/null; true'
for i in $(seq 1 60); do [[ $(gs "systemctl is-active $M") != activating ]] && break; sleep 5; done; r=$(res $M)
if [[ $st1 == activating && $r == success ]]; then record "BD-AC-49" PASS "unit 'activating' after ~2 min while restic mount held the repository, Result=success once the mount stopped"
else record "BD-AC-49" FAIL "st1=$st1 r=$r"; fi
