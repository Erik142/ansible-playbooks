#!/usr/bin/env bash
# GS-AC-67 (T-18): secrets are in no snapshot. Run after garage-v3-run.sh (needs a completed btrbk run). VM only.
# Root IDs are only unique per btrfs filesystem (the VM has @data and @containers both as ID 256 on their
# own filesystems), so each root ID is compared together with its filesystem UUID.
set -uo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
L="$OUT/garage-v3"; mkdir -p "$L"
D=/mnt/data; C=/mnt/containers; B=/mnt/backup/btrbk
gs 'for c in $(snapper list-configs | tail -n +3 | cut -d" " -f1); do snapper -c $c create -d garage-v3 >/dev/null; done; snapper list-configs' >"$L/snapper.txt" 2>&1
rid() { gs "echo \$(findmnt -no UUID -T $1):\$(btrfs inspect-internal rootid $1)"; }
fsr=$(gs 'findmnt -no FSROOT -T /var/lib/garage/secrets')
sid=$(rid /var/lib/garage/secrets); ids=""; clash=0
for p in $D $C $D/garage $C/garage/meta; do x=$(rid $p); ids+=" $p=${x#*:}"; [[ $x == "$sid" ]] && clash=1; done
nfound=$(gs "find /mnt/data/.snapshots /mnt/containers/.snapshots /mnt/data/.btrbk /mnt/containers/.btrbk $D/.btrbk-garage $C/.btrbk-garage-meta /mnt/backup/btrbk \\( -name rpc_secret -o -name admin_token \\) 2>/dev/null | wc -l")
check GS-AC-67/fsroot "findmnt FSROOT of /var/lib/garage/secrets = $fsr" test "$fsr" = "/@/var"
check GS-AC-67/rootid "secrets root id ${sid#*:} (fs ${sid%%:*}) differs, per filesystem, from$ids" test $clash -eq 0
check GS-AC-67/find "no rpc_secret/admin_token in snapper snapshots (created for: $(tail -n +3 "$L/snapper.txt" | cut -d' ' -f1 | tr '\n' ' ')), btrbk or backup directories (found $nfound)" test "$nfound" -eq 0
