#!/usr/bin/env bash
# VM run V1 for the Garage feature (T-16): storage, secrets, service, ports, restarts,
# no-layout state. VM only (tests/vm/ans.sh refuses any other target).
#   FIXTURE_VM_DIR=~/.cache/nas-fixture-vm-garage tests/vm/scenarios/garage-v1-run.sh
# Needs the VM running with snapshot `clean`. Resets to `clean` between destructive cases.
# Appends PASS/FAIL lines to $FIXTURE_VM_DIR/results.tsv.
set -uo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# GS-FR-65 sets s3.example.test, which GS-FR-135 refuses: pass a valid domain here (finding F-1).
DOM=s3.de.int.wahlberger.dev
RPC=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
TOK=fixture-garage-not-a-secret-0123456789
L="$OUT/garage-v1"; mkdir -p "$L"
gplay() { # gplay <log> [extra ansible args...]
  local log=$1; shift
  play site.yml --tags garage -e "garage_s3_domain=$DOM" "$@" >"$log" 2>&1
}
changed_of() { sed -n 's/.*changed=\([0-9]*\).*/\1/p' "$1" | tail -1; }
nosecret() { ! grep -qE "$RPC|$TOK|${RPC:0:63}" "$1"; }
cnet() { gs "podman run --rm --network systemd-caddy docker.io/library/busybox:1.37 $*"; }
chk() { # chk <scenario> <evidence> <shell condition evaluated here>
  if eval "$3"; then record "$1" PASS "$2"; else record "$1" FAIL "$2"; fi
}
resetclean() { ( cd "$NAS_DIR" && tests/vm/reset.sh clean >/dev/null 2>&1 ) && wait_ssh 240; }

# ---- GS-AC-46, GS-AC-40, GS-AC-43 on a fresh host --------------------------------------
gplay "$L/ac46.log" --check; rc=$?
skipped=$(grep -c 'skipping' "$L/ac46.log")
wl=$(grep -A1 'TASK \[garage : Wait until' "$L/ac46.log" | tail -1)
chk GS-AC-46 "check mode on fresh host rc=$rc; readiness wait line: ${wl:0:60}" "[[ $rc -eq 0 && '$wl' == skipping* ]]"
gplay "$L/ac40.log" -e garage_enabled=false; rc=$?
chk GS-AC-40 "flag false: rc=$rc changed=$(changed_of "$L/ac40.log"); paths absent (btrbk.service part: V3)" \
  "[[ $rc -eq 0 && \"$(changed_of "$L/ac40.log")\" == 0 ]] && ! g 'test -e /mnt/data/garage -o -e /mnt/containers/garage/meta -o -e /etc/containers/systemd/garage.container'"
gplay "$L/ac43.log" -e backup_disk_enabled=false; rc=$?
chk GS-AC-43 "rc=$rc, names both flags, nothing created" \
  "[[ $rc -ne 0 ]] && grep -q 'garage_enabled' '$L/ac43.log' && grep -q 'backup_disk_enabled' '$L/ac43.log'"
g 'test ! -e /mnt/data/garage && test ! -e /etc/containers/systemd/garage.container' && echo "AC-43 nothing created"

# ---- GS-AC-25: invalid input rows, -vvv, no secret value ------------------------------
row() { # row <label> <ansible extra args...>
  local lbl=$1; shift
  gplay "$L/ac25-$lbl.log" -vvv "$@"; local rc=$?
  local ok=1
  [[ $rc -ne 0 ]] || ok=0
  nosecret "$L/ac25-$lbl.log" || ok=0
  g 'test ! -e /mnt/data/garage && test ! -e /etc/containers/systemd/garage.container' || ok=0
  if [[ $ok -eq 1 ]]; then record "GS-AC-25/$lbl" PASS "rc=$rc, refused before any change, no secret in -vvv output"
  else record "GS-AC-25/$lbl" FAIL "rc=$rc"; fi
}
row rpc-empty        -e vault_garage_rpc_secret=
row rpc-63hex        -e "vault_garage_rpc_secret=${RPC:0:63}"
row token-31         -e "vault_garage_admin_token=${TOK:0:31}"
row domain-example   -e garage_s3_domain=s3.example.org
row domain-empty     -e garage_s3_domain=
row meta-path        -e garage_meta_path=/mnt/data/garage-meta
for lbl in rpc-empty rpc-63hex token-31 domain-example domain-empty meta-path; do
  case $lbl in
    rpc*) w=vault_garage_rpc_secret;; token*) w=vault_garage_admin_token;;
    domain*) w=garage_s3_domain;; meta*) w=garage_meta_path;;
  esac
  grep -q "$w" "$L/ac25-$lbl.log" && echo "  names $w ($lbl)" || echo "  MISSING name $w ($lbl)"
done

# ---- GS-AC-68: secrets dir inside a snapshotted subvolume ----------------------------
for p in /mnt/containers/garage/secrets /mnt/data/garage-secrets; do
  gplay "$L/ac68.log" -e "garage_secrets_dir=$p"; rc=$?
  chk "GS-AC-68/$p" "rc=$rc, names path" "[[ $rc -ne 0 ]] && grep -q '$p' '$L/ac68.log' && grep -qiE 'snapper config|btrbk source' '$L/ac68.log'"
  g "test ! -e $p" && echo "  $p absent afterwards"
done

# ---- GS-AC-14: tmpfs refusal ---------------------------------------------------------
gs 'mkdir -p /mnt/garage-test && mount -t tmpfs tmpfs /mnt/garage-test'
gplay "$L/ac14a.log" -e garage_mount_path=/mnt/garage-test; rc=$?
chk GS-AC-14/a "rc=$rc names /mnt/garage-test and tmpfs" "[[ $rc -ne 0 ]] && grep -q '/mnt/garage-test' '$L/ac14a.log' && grep -q tmpfs '$L/ac14a.log'"
gplay "$L/ac14b.log" -e garage_meta_mount_path=/mnt/garage-test -e garage_config_dir=/mnt/garage-test/garage; rc=$?
chk GS-AC-14/b "rc=$rc names /mnt/garage-test and tmpfs" "[[ $rc -ne 0 ]] && grep -q '/mnt/garage-test' '$L/ac14b.log' && grep -q tmpfs '$L/ac14b.log'"
check GS-AC-14/nocreate "nothing below tmpfs, no garage.container" \
  g 'test -z "$(ls -A /mnt/garage-test)" && test ! -e /etc/containers/systemd/garage.container'
gs 'umount /mnt/garage-test; rmdir /mnt/garage-test'

# Every refusal above must leave the host untouched (GS-E-04, E-32, E-01): a leftover would hide GS-AC-16.
chk "GS-AC-14/25/68 left no change" "no garage subvolume, account or unit exists" \
  "gs 'test ! -e /mnt/data/garage -a ! -e /mnt/containers/garage -a ! -e /etc/containers/systemd/garage.container -a ! -e /var/lib/garage' && ! gs 'getent passwd garage'"
# ---- GS-AC-16: plain directory refused -----------------------------------------------
for p in /mnt/data/garage /mnt/containers/garage/meta; do
  gs "mkdir -p $p && echo keep >$p/keep.txt"
  k1=$(gs "sha256sum $p/keep.txt | cut -d' ' -f1")
  gplay "$L/ac16.log"; rc=$?
  k2=$(gs "sha256sum $p/keep.txt | cut -d' ' -f1")
  cp "$L/ac16.log" "$L/ac16-$(basename "$p").log"
  chk "GS-AC-16/$p" "rc=$rc, names path + not a btrfs subvolume, keep.txt unchanged, no unit/secrets" \
    "[[ $rc -ne 0 && '$k1' == '$k2' ]] && grep -q '$p' '$L/ac16.log' && grep -qi 'subvolume' '$L/ac16.log' && ! gs 'test -e /etc/containers/systemd/garage.container -o -e /var/lib/garage/secrets/rpc_secret'"
  gs "rm -rf $p; rmdir /mnt/containers/garage 2>/dev/null; true"
done

# ---- GS-AC-19: non-empty metadata subvolume without C is left unchanged ----------------
gs 'mkdir -p /mnt/containers/garage && btrfs subvolume create /mnt/containers/garage/meta >/dev/null && echo x >/mnt/containers/garage/meta/pre.txt'
b=$(gs 'lsattr -d /mnt/containers/garage/meta')
gplay "$L/ac19.log"; rc=$?
a=$(gs 'lsattr -d /mnt/containers/garage/meta')
chk GS-AC-19 "run rc=$rc; lsattr before/after identical: '${b%% *}' / '${a%% *}'" "[[ '${b%% *}' == '${a%% *}' ]] && [[ '${b%% *}' != *C* ]]"
resetclean || { echo "reset failed"; exit 1; }

# ---- Fresh store: the role run (GS-AC-75, 01, 02, 03, 17, 18, 22, 35, 36, 37, 11) -----------
gplay "$L/main.log"; rc=$?
check GS-AC-22/run "fresh role run rc=$rc" test $rc -eq 0
[[ $rc -eq 0 ]] || { tail -30 "$L/main.log"; exit 1; }
chk GS-AC-01 "both mounts btrfs" "[[ \"\$(vm_ssh 'findmnt -no FSTYPE /mnt/data; findmnt -no FSTYPE /mnt/containers' | tr '\n' ' ')\" == 'btrfs btrfs ' ]]"
check GS-AC-02 "both are subvolumes and listed" gs 'btrfs subvolume show /mnt/data/garage >/dev/null && btrfs subvolume show /mnt/containers/garage/meta >/dev/null && btrfs subvolume list -o /mnt/data | grep -q "garage$" && btrfs subvolume list -o /mnt/containers | grep -q "garage/meta$"'
o=$(g 'for p in /mnt/data/garage /mnt/data/garage/data /mnt/containers/garage/meta /var/lib/garage/secrets; do sudo stat -c "%a %U:%G" $p; done; test ! -e /mnt/data/garage/meta && echo nometa' | tr '\n' '|')
check GS-AC-03 "$o" test "$o" = '700 root:root|700 garage:garage|700 garage:garage|750 root:garage|nometa|'
o=$(g 'sudo stat -c "%a %U:%G" /var/lib/garage/secrets/rpc_secret /var/lib/garage/secrets/admin_token; sudo find /mnt/containers/garage /mnt/data/garage \( -name rpc_secret -o -name admin_token \); systemctl is-active garage.service' | tr '\n' '|')
check GS-AC-22 "$o" test "$o" = '400 garage:garage|400 garage:garage|active|'
o=$(gs 'podman top garage huser | tail -1; id -u garage; getent passwd garage' | tr '\n' '|')
uid=$(gs 'id -u garage')
chk GS-AC-17 "huser=$o (podman prints the user name, uid $uid from id -u)" "[[ '$o' == garage\|$uid\|garage:x:$uid:*:/usr/sbin/nologin\| && $uid -lt 1000 && $uid -ne 0 ]]"
check GS-AC-18 "$(gs 'lsattr -d /mnt/containers/garage/meta')" gs 'lsattr -d /mnt/containers/garage/meta | cut -d" " -f1 | grep -q C'
# 35
t0=$(date +%s)
gs 'systemctl restart garage.service'
ok=0; for _ in $(seq 1 30); do gs 'podman exec garage /garage status >/dev/null 2>&1' && { ok=1; break; }; sleep 2; done
check GS-AC-35 "restart then garage status exit 0 after $(( $(date +%s) - t0 )) s (config read from declared path; image has no /etc/garage.toml)" test $ok -eq 1
check GS-AC-36 "healthcheck run exit 0 + command in inspect" gs 'podman healthcheck run garage && podman inspect garage | grep -q "/garage status"'
o=$(gs 'systemctl show garage.service -p OnFailure -p Restart -p RequiresMountsFor; systemctl show -p Wants default.target' | tr '\n' '|')
chk GS-AC-37 "$o" "[[ '$o' == *'OnFailure=notify-failure@garage.service.service'* && '$o' == *Restart=always* && '$o' == *'/mnt/data'* && '$o' == *'/mnt/containers/garage'* && '$o' == *garage.service* ]]"
# 75
st=$(gs 'podman exec garage /garage status; echo rc=$?' 2>&1)
put=$(gs "podman run --rm --network systemd-caddy -e AWS_ACCESS_KEY_ID=GKfake0000000000000000000 -e AWS_SECRET_ACCESS_KEY=0000000000000000000000000000000000000000000000000000000000000000 -e AWS_DEFAULT_REGION=garage -e AWS_EC2_METADATA_DISABLED=true docker.io/amazon/aws-cli:2.38.1 --endpoint-url http://garage:3900 s3api put-object --bucket sstate --key pre-layout --body /etc/hostname; echo rc=\$?" 2>&1 | tail -3)
chk GS-AC-75 "status rc=0 + NO ROLE ASSIGNED; signed PUT before layout: $(tr '\n' ' ' <<<"$put" | cut -c1-160)" \
  "[[ '$st' == *rc=0* && '$st' == *'NO ROLE ASSIGNED'* && '$put' != *rc=0* ]]"
# 11
gs 'podman pull -q docker.io/library/busybox:1.37 >/dev/null'
sc=$(gs "for p in 3900 3901 3902 3903; do timeout 3 bash -c \"</dev/tcp/$VMIP/\$p\" 2>/dev/null && echo open\$p; done; ss -ltnH '( sport >= :3900 and sport <= :3903 )'" 2>&1)
cn=$(cnet 'sh -c "for p in 3900 3902 3901 3903; do nc -z -w 3 garage \$p && echo open\$p; done"' 2>/dev/null)
chk GS-AC-11 "host side nothing open/listening ('$sc'); caddy.network open: $(tr '\n' ' ' <<<"$cn")" \
  "[[ -z '$sc' && '$cn' == *open3900* && '$cn' == *open3902* && '$cn' != *open3901* && '$cn' != *open3903* ]]"

# ---- Test setup (T-13), then GS-AC-15 --------------------------------------------------
"$SCEN_DIR/garage-test-setup.sh" || echo "test setup failed"
idn=$(gs 'btrfs subvolume show /mnt/data/garage | awk "/Subvolume ID/{print \$3}"')
idm=$(gs 'btrfs subvolume show /mnt/containers/garage/meta | awk "/Subvolume ID/{print \$3}"')
gplay "$L/ac15.log"; rc=$?
idn2=$(gs 'btrfs subvolume show /mnt/data/garage | awk "/Subvolume ID/{print \$3}"')
idm2=$(gs 'btrfs subvolume show /mnt/containers/garage/meta | awk "/Subvolume ID/{print \$3}"')
chk=$(gs 'podman exec garage /garage bucket info sstate 2>/dev/null | grep -iE "objects"' | tr '\n' ' ')
chk GS-AC-15 "rc=$rc ids N=$idn/$idn2 M=$idm/$idm2; $chk" "[[ $rc -eq 0 && '$idn' == '$idn2' && '$idm' == '$idm2' ]]"

# ---- GS-AC-71: kill and restart ---------------------------------------------------------
n0=$(gs 'systemctl show garage.service -p NRestarts --value')
gs 'podman kill garage >/dev/null'
n1=$n0; for _ in $(seq 1 15); do n1=$(gs 'systemctl show garage.service -p NRestarts --value'); [[ $n1 -eq $((n0 + 1)) ]] && break; sleep 2; done
ok=0; for _ in $(seq 1 30); do gs 'podman exec garage /garage status >/dev/null 2>&1' && { ok=1; break; }; sleep 2; done
chk GS-AC-71 "NRestarts $n0 -> $n1, status ok=$ok" "[[ $n1 -eq $((n0 + 1)) && $ok -eq 1 ]]"

# ---- GS-AC-67 (rootid / FSROOT part; btrbk run is V3) ---------------------------------
fsr=$(gs 'findmnt -no FSROOT -T /var/lib/garage/secrets')
snp=$(gs 'find $(snapper list-configs | awk -F"|" "NR>2{gsub(/ /,\"\",\$2);print \$2}")/.snapshots /mnt/data/.btrbk /mnt/containers/.btrbk -name rpc_secret -o -name admin_token 2>/dev/null | wc -l')
chk GS-AC-67 "FSROOT=$fsr; secret files in snapshot dirs: $snp (btrbk run + snapper create: not run)" "[[ '$fsr' == /@/var && $snp -eq 0 ]]"

# ---- GS-AC-72: readiness wait times out -----------------------------------------------
resetclean || { echo "reset failed"; exit 1; }
t0=$(date +%s)
gplay "$L/ac72.log" -e garage_ready_timeout_sec=10 -e garage_image=docker.io/library/busybox:1.37; rc=$?
dt=$(( $(date +%s) - t0 ))
chk GS-AC-72 "rc=$rc in ${dt}s overall; failed task is the readiness wait naming garage_ready_timeout_sec" \
  "[[ $rc -ne 0 ]] && grep -q 'garage_ready_timeout_sec' '$L/ac72.log' && grep -q 'Readiness wait failed' '$L/ac72.log'"

# ---- GS-AC-05 ----------------------------------------------------------------------------
record GS-AC-05 SKIPPED "samba role is not part of the VM stack (no smbclient/testparm)"
echo "done; results in $RESULTS_TSV"
