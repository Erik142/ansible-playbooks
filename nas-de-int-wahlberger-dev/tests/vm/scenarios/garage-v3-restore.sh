#!/usr/bin/env bash
# GS-AC-55 (restore drill) and GS-AC-56 (skew) for T-18. Run after garage-v3-run.sh (needs its <ts> in
# $OUT/garage-v3/ts1). VM only. The restore steps below are the ones the role README (T-21) must state.
set -uo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
L="$OUT/garage-v3"; mkdir -p "$L"
GL='source /var/tmp/garage-v3-guest.sh; creds;'
D=/mnt/data; C=/mnt/containers; B=/mnt/backup/btrbk
HDR='Hash  RC  Errors  Last error  Next try'
vm_ssh 'sudo -n tee /var/tmp/garage-v3-guest.sh >/dev/null' <"$SCEN_DIR/garage-v3-guest.sh"
TS=$(cat "$L/ts1"); S=$(gs 'cat /var/tmp/garage-test-setup.sha256' | awk '$2=="up"{print $1}')
SECDIR=/var/lib/garage/secrets

# ---- GS-AC-55: selftest/up deleted after the run, secrets dir emptied, README restore steps with <ts> ----
gs "$GL echo sha=\$(getsha selftest/up)" | tail -1 | grep -q "sha=$S" || echo "note: selftest/up sha before delete differs from S"
gs "$GL s3 delete-object --bucket sstate --key selftest/up >/dev/null; echo deleted"
gs "$GL head404 selftest/up && echo gone" | grep -q gone || echo "warn: selftest/up not deleted"
gs "rm -f $SECDIR/rpc_secret $SECDIR/admin_token; ls -A $SECDIR | wc -l" >"$L/secdir-empty"
# README restore steps: stop; replace both subvolumes by writable snapshots of the same-<ts> pair
gs "source /var/tmp/garage-v3-guest.sh; restore_stop_replace $B/garage/garage.$TS $B/garage-meta/garage-meta.$TS" >"$L/restore-1.log" 2>&1; rc=$?
check GS-AC-55/restore-copy "garage stopped, data and metadata subvolumes restored from <ts>=$TS (rc=$rc)" test $rc -eq 0
# re-render the secrets from Vault (fixture values) with --tags garage; the role starts the service
play site.yml --tags garage >"$L/restore-ansible.log" 2>&1; arc=$?
gs 'systemctl start garage.service'
secs=$(gs "source /var/tmp/garage-v3-guest.sh; wait_status"); src=$?
check GS-AC-55/secrets "ansible rc=$arc; secret modes: $(gs "stat -c '%a %U:%G' $SECDIR/rpc_secret $SECDIR/admin_token" | tr '\n' ',')" \
  bash -c "[ $arc -eq 0 ] && [ \"$(gs "stat -c '%a %U:%G' $SECDIR/rpc_secret $SECDIR/admin_token" | tr '\n' ',')\" = '400 garage:garage,400 garage:garage,' ]"
check GS-AC-55/status "garage status exit 0, ${secs}s after the start (limit 60)" bash -c "[ $src -eq 0 ] && [ '$secs' -le 60 ]"
got=$(gs "$GL getsha selftest/up")
check GS-AC-55/object "selftest/up reads back with sha256 S ($got vs $S)" test "$got" = "$S"
errs=$(gs 'podman exec garage /garage block list-errors 2>/dev/null')
check GS-AC-55/block-errors "block list-errors prints only the header line: [$errs]" test "$errs" = "$HDR"
[[ $rc -eq 0 ]] && gs "source /var/tmp/garage-v3-guest.sh; restore_cleanup" >>"$L/restore-1.log" 2>&1

# ---- GS-AC-56: skew between the two snapshots ----
SK_M=$C/skew-meta; SK_D=$D/skew-data
gs "$GL put skew/A A 65536; cat \$W/sha.A" >"$L/shaA.txt"; shaA=$(tail -1 "$L/shaA.txt")
gs "btrfs subvolume snapshot -r $C/garage/meta $SK_M >/dev/null; date +%s.%N" >"$L/t1"
gs "$GL put skew/B B 65536; s3 delete-object --bucket sstate --key skew/A >/dev/null; btrfs subvolume snapshot -r $D/garage $SK_D >/dev/null; date +%s.%N; cat \$W/sha.B" >"$L/t2"
dt=$(python3 -I -c "import sys;a=float(open('$L/t1').read().split()[0]);b=float(open('$L/t2').read().split()[0]);print(round(b-a,1))")
gs "$GL head404 skew/A && echo A404; getsha skew/B" >"$L/pre.txt"
echo "skew: snapshots $dt s apart; before restore: $(tr '\n' ' ' <"$L/pre.txt" | cut -c1-120)"
gs "source /var/tmp/garage-v3-guest.sh; restore_stop_replace $SK_D $SK_M" >"$L/restore-2.log" 2>&1; rc=$?
gs 'systemctl start garage.service'
secs=$(gs "source /var/tmp/garage-v3-guest.sh; wait_status"); src=$?
check GS-AC-56/start "snapshots ${dt}s apart (limit 10), restore rc=$rc, garage.service active, garage status exit $src after ${secs}s" \
  bash -c "[ $rc -eq 0 ] && [ $src -eq 0 ] && python3 -I -c 'import sys; sys.exit(0 if $dt <= 10 else 1)' && [ \"$(gs 'systemctl is-active garage.service')\" = active ]"
gotA=$(gs "$GL getsha skew/A")
check GS-AC-56/A "A reads back with its original sha256 ($gotA vs $shaA)" test "$gotA" = "$shaA"
b404=$(gs "$GL head404 skew/B && echo 404")
check GS-AC-56/B "GET/HEAD of B returns 404 ($b404)" test "$b404" = 404
[[ $rc -eq 0 ]] && gs "source /var/tmp/garage-v3-guest.sh; restore_cleanup; btrfs subvolume delete $SK_M $SK_D >/dev/null; $GL s3 delete-object --bucket sstate --key skew/A >/dev/null; true" >>"$L/restore-2.log" 2>&1

# ---- next btrbk run after the restore (day +1): GS-AC-04 later-run case, GS-AC-20 again, restored subvolumes ----
quiet_timers; nextday; T2=$(now)
gs 'systemctl start btrbk.service'; r=$(res btrbk.service 2>/dev/null || gs 'systemctl show -p Result --value btrbk.service')
TS2=$(gs "ls -1 $D/.btrbk-garage | sed -n 's/^garage\.//p' | sort | tail -1"); TSM2=$(gs "ls -1 $C/.btrbk-garage-meta | sed -n 's/^garage-meta\.//p' | sort | tail -1")
check GS-AC-20/run2-after-restore "btrbk.service Result=$r after the restore; garage.$TS2 / garage-meta.$TSM2 same <ts>, received" \
  bash -c "[ '$r' = success ] && [ -n '$TS2' ] && [ '$TS2' = '$TSM2' ] && [ '$TS2' != '$TS' ]" 
gs "journalctl -u btrbk.service --since '$T2' --no-pager -o cat | grep -E '^(>>>|\\+\\+\\+|!!!|---)|ERROR|WARN' | head -20" >"$L/run2-journal.txt"
echo "run 2 journal: $(tr '\n' '|' <"$L/run2-journal.txt" | cut -c1-400)"
DS=$(gs "ls -1d $D/.btrbk/data.* | sort | tail -1"); CS=$(gs "ls -1d $C/.btrbk/containers.* | sort | tail -1")
nf=$(gs "find $DS/garage $DS/.btrbk-garage $CS/garage/meta $CS/.btrbk-garage-meta -mindepth 1 -not -type d 2>&1 | wc -l")
nstub=$(gs "ls -1 $DS/.btrbk-garage | wc -l")
check GS-AC-04/run2 "later run: $(basename "$DS") holds $nstub stub(s) in .btrbk-garage, non-directory entries below stubs: $nf" bash -c "[ $nf -eq 0 ] && [ $nstub -ge 1 ]"
