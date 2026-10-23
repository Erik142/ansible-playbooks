#!/usr/bin/env bash
# VM run V3 for the Garage feature (T-18): btrbk Garage sources, backup under upload load, restore drill,
# skew. VM only (tests/vm/ans.sh refuses any other target). Needs the V2 state on the VM (layout, buckets,
# key test-rw, object selftest/up) and the backup disk initialised + the stack applied (tests/vm/stack.sh).
#   FIXTURE_VM_DIR=~/.cache/nas-fixture-vm-garage tests/vm/scenarios/garage-v3-run.sh
# Appends PASS/FAIL lines to $FIXTURE_VM_DIR/results.tsv.
set -uo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
L="$OUT/garage-v3"; mkdir -p "$L"
putg() { vm_ssh "sudo -n tee $2 >/dev/null" <"$1"; }
GL='source /var/tmp/garage-v3-guest.sh; creds;'
changed_of() { sed -n 's/.*changed=\([0-9]*\).*/\1/p' "$1" | tail -1; }
res() { gs "systemctl show -p Result --value $1"; }
D=/mnt/data; C=/mnt/containers; B=/mnt/backup/btrbk
putg "$SCEN_DIR/garage-v3-guest.sh" /var/tmp/garage-v3-guest.sh
gs 'mkdir -p /var/tmp/g3'
quiet_timers

# ---- GS-AC-53: invalid per-source snapshot_dir refused, btrbk.conf unchanged ----
src() { printf '[{"name":"data","path":"/mnt/data"},{"name":"containers","path":"/mnt/containers"},{"name":"garage-meta","path":"/mnt/containers/garage/meta","mount_path":"/mnt/containers","snapshot_dir":"/mnt/containers/.btrbk-garage-meta"},{"name":"garage","path":"/mnt/data/garage","mount_path":"/mnt/data","snapshot_dir":"%s"}]' "$1"; }
conf_h() { gs 'sha256sum /etc/btrbk/btrbk.conf'; }
h0=$(conf_h); i=0
for v in '.btrbk-garage' '/mnt/data/samba/Delat/.btrbk-garage' '/mnt/data/garage/.snap' '/mnt/containers/.btrbk-garage'; do
  i=$((i + 1))
  play site.yml --tags btrbk -e "{\"btrbk_sources\":$(src "$v")}" >"$L/ac53-$i.log" 2>&1; rc=$?
  check "GS-AC-53/$i" "snapshot_dir $v: rc=$rc, names garage and the value, btrbk.conf unchanged" \
    bash -c "[ $rc -ne 0 ] && grep -q \"garage\" '$L/ac53-$i.log' && grep -qF -- '$v' '$L/ac53-$i.log' && [ \"$h0\" = \"$(conf_h)\" ]"
done

# ---- GS-AC-21: absent Garage subvolume refused before any change ----
gs 'systemctl stop garage.service; mv /mnt/data/garage /mnt/data/garage.away'
play site.yml --tags btrbk >"$L/ac21-1.log" 2>&1; rc=$?
check "GS-AC-21/garage" "rc=$rc, message names /mnt/data/garage" \
  bash -c "[ $rc -ne 0 ] && grep -q '/mnt/data/garage' '$L/ac21-1.log'"
check "GS-AC-21/garage-absent" "/mnt/data/garage still does not exist" gs 'test ! -e /mnt/data/garage'
gs 'mv /mnt/data/garage.away /mnt/data/garage; mv /mnt/containers/garage/meta /mnt/containers/garage/meta.away'
play site.yml --tags btrbk >"$L/ac21-2.log" 2>&1; rc=$?
check "GS-AC-21/garage-meta" "rc=$rc, message names /mnt/containers/garage/meta" \
  bash -c "[ $rc -ne 0 ] && grep -q '/mnt/containers/garage/meta' '$L/ac21-2.log'"
check "GS-AC-21/garage-meta-absent" "/mnt/containers/garage/meta still does not exist" gs 'test ! -e /mnt/containers/garage/meta'
gs 'mv /mnt/containers/garage/meta.away /mnt/containers/garage/meta; systemctl start garage.service'
gs "$GL wait_status" >/dev/null

# ---- GS-AC-68: secrets directory inside a snapshotted subvolume refused ----
for p in /mnt/containers/garage/secrets /mnt/data/garage-secrets; do
  play site.yml --tags garage -e "garage_secrets_dir=$p" >"$L/ac68.log" 2>&1; rc=$?
  ex=$(gs "test -e $p && echo exists || echo absent")
  check "GS-AC-68/$p" "rc=$rc, message names the path, path afterwards $ex" \
    bash -c "[ $rc -ne 0 ] && grep -q '$p' '$L/ac68.log' && [ '$ex' = absent ]"
done

# ---- backup run 1 under continuous upload load (live LMDB, GS-R-03) ----
gs "$GL echo S=\$(getsha selftest/up)" >"$L/S.txt" 2>&1; S=$(sed -n 's/^S=//p' "$L/S.txt")
echo "selftest/up sha before backup: $S"
gs "$GL load_start; sleep 8; echo count0=\$(objcount)" | tail -1 >"$L/count0"
gs 'systemctl start btrbk.service'; r=$(res btrbk.service)
gs "$GL echo count1=\$(objcount)" | tail -1 >"$L/count1"
gs "$GL load_stop; echo count2=\$(objcount)" | tail -1 >"$L/count2"
echo "run 1 Result=$r; $(cat "$L"/count0 "$L"/count1 "$L"/count2 | tr '\n' ' ')"
check GS-AC-20/run1 "btrbk.service Result=$r, uploads ran during the run ($(cat "$L"/count0 "$L"/count1 | tr '\n' ' '))" \
  bash -c "[ '$r' = success ] && [ \"$(sed 's/count.=//' "$L/count0")\" != \"$(sed 's/count.=//' "$L/count2")\" ]"
TS=$(gs "ls -1 $D/.btrbk-garage | sed -n 's/^garage\.//p' | sort | tail -1")
TSM=$(gs "ls -1 $C/.btrbk-garage-meta | sed -n 's/^garage-meta\.//p' | sort | tail -1")
echo "ts garage=$TS meta=$TSM"
echo "$TS" >"$L/ts1"
check GS-AC-20/ts-pair "garage.$TS and garage-meta.$TSM, same <ts> (GS-A-17)" test -n "$TS" -a "$TS" = "$TSM"
check GS-AC-20/targets "received garage.$TS and garage-meta.$TS exist on the backup disk" \
  gs "test -d $B/garage/garage.$TS/data && test -d $B/garage-meta/garage-meta.$TS"
check GS-AC-20/meta-entries "received garage-meta.<ts> lists the same top-level entries as the source snapshot" \
  gs "diff <(ls -A $B/garage-meta/garage-meta.$TS) <(ls -A $C/.btrbk-garage-meta/garage-meta.$TS)"
check GS-AC-20/no-inside "no .btrbk inside the Garage subvolumes" gs "test ! -e $D/garage/.btrbk && test ! -e $C/garage/meta/.btrbk"
check GS-AC-20/modes "700 root:root on both snapshot directories" \
  bash -c "[ \"$(gs "stat -c '%a %U:%G' $D/.btrbk-garage $C/.btrbk-garage-meta" | tr '\n' ',')\" = '700 root:root,700 root:root,' ]"

# ---- GS-AC-04: general snapshots hold stubs only, no secrets ----
DS=$(gs "ls -1d $D/.btrbk/data.* | sort | tail -1"); CS=$(gs "ls -1d $C/.btrbk/containers.* | sort | tail -1")
nf=$(gs "find $DS/garage $DS/.btrbk-garage $CS/garage/meta $CS/.btrbk-garage-meta -mindepth 1 -not -type d 2>&1 | wc -l")
chk=$(gs "test -d $DS/garage && test -d $CS/garage/meta && test -d $DS/.btrbk-garage && test -d $CS/.btrbk-garage-meta && echo y")
sec=$(gs "find $CS -name rpc_secret -o -name admin_token | wc -l")
check GS-AC-04/run1 "stub dirs present, non-directory entries below stubs: $nf, secret files in $(basename "$CS"): $sec" bash -c "[ '$chk' = y ] && [ $nf -eq 0 ] && [ $sec -eq 0 ]"

# ---- GS-AC-45 [V]: backup-disk-health.service with the Garage freshness paths ----
play site.yml --tags backup_disk -e "backup_disk_uuid=$(cat "$FIXTURE_VM_DIR/backup_uuid")" -e '{"backup_disk_freshness_checks":[{"path":"/mnt/backup/btrbk/data","max_age_hours":26},{"path":"/mnt/backup/btrbk/containers","max_age_hours":26},{"path":"/mnt/data/restic-repos/cloud/snapshots","max_age_hours":26},{"path":"/mnt/backup/btrbk/garage","max_age_hours":26},{"path":"/mnt/backup/btrbk/garage-meta","max_age_hours":26}]}' >"$L/ac45-apply.log" 2>&1
gs 'systemctl start backup-disk-health.service'; rc=$?
check GS-AC-45/V "backup-disk-health.service exit $rc (Result=$(res backup-disk-health.service)) with freshness paths garage and garage-meta" test $rc -eq 0

# GS-AC-67 is in garage-v3-secrets.sh (run after this script).
