#!/usr/bin/env bash
# Roll the fixture VM back to a snapshot (default: clean) and boot it.
# Discards everything done since: formatted backup disk, deployed units, ...
#   ./reset.sh [name]
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NAME="${1:-clean}"
vm_running && vm_stop
if vm_running; then echo "VM still running, aborting" >&2; exit 1; fi
for d in "${DISKS[@]}"; do
  "$QEMU_IMG" snapshot -l "$(disk_path "$d")" | awk '{print $2}' | grep -qx "$NAME" ||
    { echo "snapshot '$NAME' missing on $d" >&2; exit 1; }
done
for d in "${DISKS[@]}"; do "$QEMU_IMG" snapshot -a "$NAME" "$(disk_path "$d")"; done
echo ">> rolled back to '$NAME'"
vm_start
wait_ssh 300
