#!/usr/bin/env bash
# Stop the fixture VM (graceful poweroff). Disks are kept; `./down.sh --destroy`
# also deletes every disk, so the next up.sh builds a fresh VM (the cached
# tw-base.qcow2 image is kept unless --purge is given).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

vm_stop
case "${1:-}" in
  --destroy | --purge)
    for d in "${DISKS[@]}"; do rm -f "$(disk_path "$d")"; done
    rm -f "$VARS" "$CONSOLE_LOG"
    [[ "${1}" == "--purge" ]] && rm -f "$TW_BASE" "$BASE_IMG" "$SEED"
    echo "disks removed"
    ;;
esac
