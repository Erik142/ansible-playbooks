#!/usr/bin/env bash
# Helpers for the VM scenario scripts. Source after exporting FIXTURE_VM_DIR.
# shellcheck shell=bash
SCEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAS_DIR="$(cd "$SCEN_DIR/../../.." && pwd)"
# shellcheck source=../lib.sh
source "$SCEN_DIR/../lib.sh"
ANS="$NAS_DIR/tests/vm/ans.sh"
OUT="${FIXTURE_VM_DIR}/out"; mkdir -p "$OUT"
RESULTS_TSV="${FIXTURE_VM_DIR}/results.tsv"
BK=/dev/disk/by-id/virtio-FIXTUREBACKUP
SC=/dev/disk/by-id/virtio-FIXTURESCRATCH

g() { vm_ssh "$@"; }                 # run in guest as fixture
gs() { vm_ssh "sudo -n bash -c $(printf '%q' "$*")"; }  # run in guest as root
play() { ( cd "$NAS_DIR" && "$ANS" ansible-playbook "$@" ) </dev/null; }
adhoc() { ( cd "$NAS_DIR" && "$ANS" ansible "$@" ) </dev/null; }

record() { # record <scenario> <PASS|FAIL|SKIPPED> <evidence>
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$RESULTS_TSV"
  printf '[%s] %s: %s\n' "$2" "$1" "$3"
}
check() { # check <scenario> <evidence> <command...>  (PASS when command succeeds)
  local sc=$1 ev=$2; shift 2
  if "$@"; then record "$sc" PASS "$ev"; else record "$sc" FAIL "$ev"; fi
}

fp() { # fingerprint of a device (stdout)
  gs "sync; d=\$(readlink -f $1); wipefs --no-act --json \$d; sfdisk --dump \$d 2>&1; dd if=\$d bs=1M count=1 2>/dev/null | sha256sum; tail_off=\$(( \$(blockdev --getsize64 \$d)/1048576 - 1 )); dd if=\$d bs=1M skip=\$tail_off count=1 2>/dev/null | sha256sum"
}
disk_blank() { # wipe signatures and zero first/last 8 MiB of a device
  gs "set -e; d=\$(readlink -f $1); swapoff \$d 2>/dev/null || true; umount /mnt/t27 2>/dev/null || true; mdadm --stop /dev/md0 2>/dev/null || true; vgremove -ff fixturevg >/dev/null 2>&1 || true; vgchange -an >/dev/null 2>&1 || true; cryptsetup close fixtureluks 2>/dev/null || true; wipefs -a \$d* >/dev/null 2>&1 || true; sz=\$(blockdev --getsize64 \$d); dd if=/dev/zero of=\$d bs=1M count=8 conv=fsync 2>/dev/null; dd if=/dev/zero of=\$d bs=1M seek=\$((sz/1048576-8)) count=8 conv=fsync 2>/dev/null; partprobe \$d 2>/dev/null || true; udevadm settle"
}

stack() { ( cd "$NAS_DIR" && "$NAS_DIR/tests/vm/stack.sh" "$@" ); }
alert_since() { # alert_since <unit> <since>: lines of the notify-failure instance units for <unit> (not our own sudo lines)
  gs "journalctl -u 'notify-failure-immediate@$1.service' -u 'notify-failure@$1.service' --since '$2' --no-pager -o cat 2>/dev/null | wc -l" 2>/dev/null | tail -1 | tr -d ' '
}
now() { gs 'date "+%Y-%m-%d %H:%M:%S"'; }

# btrbk's target_preserve keeps the FIRST snapshot of each day, so a second run on the
# same day replicates nothing. Move the guest clock one day on before each run that
# must replicate (timers are stopped so nothing fires on the jump).
quiet_timers() { gs 'timedatectl set-ntp false 2>/dev/null; systemctl stop btrbk.timer restic-server-maintenance.timer backup-disk-health.timer disk-space-check.timer snapper-timeline.timer snapper-cleanup.timer 2>/dev/null; true'; }
nextday() { gs 'date -s "+1 day" >/dev/null'; }

PW=fixture-restic-htpasswd-not-a-secret
VMIP=192.168.122.50
role_only() { ( cd "$NAS_DIR" && "$NAS_DIR/tests/vm/ans.sh" ansible-playbook site.yml --tags "$1" -e "backup_disk_uuid=$(cat "$FIXTURE_VM_DIR/backup_uuid")" "${@:2}" ) </dev/null; }
code() { gs "curl -s -m 5 -o /dev/null -w '%{http_code}' $*"; }
