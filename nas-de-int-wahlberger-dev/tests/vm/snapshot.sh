#!/usr/bin/env bash
# Take a named, clean snapshot of all five fixture disks (qcow2 internal
# snapshots, taken with the guest cleanly powered off so the state is
# crash-consistent-free), then boot the VM again.
#   ./snapshot.sh [name]        default name: clean
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NAME="${1:-clean}"
vm_ssh 'sync' 2>/dev/null || true
vm_stop
for d in "${DISKS[@]}"; do
  p="$(disk_path "$d")"
  "$QEMU_IMG" snapshot -d "$NAME" "$p" 2>/dev/null || true # replace an older one of that name
  "$QEMU_IMG" snapshot -c "$NAME" "$p"
done
echo ">> snapshot '$NAME' taken on: ${DISKS[*]}"
vm_start
wait_ssh 300
