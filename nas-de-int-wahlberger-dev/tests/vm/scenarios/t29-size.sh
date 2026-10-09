#!/usr/bin/env bash
# BD-AC-44: --max-size stops a client. VM only; run from the `stack` snapshot.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
role_only restic_server -e restic_server_max_size_bytes=104857600 >"$OUT/ac44-apply.log" 2>&1
sleep 3
gs 'head -c 209715200 /dev/urandom >/root/rand200; rcli backup /root/rand200 >/tmp/ac44.out 2>&1; echo rc=$?' >"$OUT/ac44.txt"
rc=$(grep -o 'rc=[0-9]*' "$OUT/ac44.txt" | cut -d= -f2); sz=$(gs 'du -sb /mnt/data/restic-repos | cut -f1'); tail=$(gs 'tail -2 /tmp/ac44.out | tr "\n" " "')
if [[ $rc -ne 0 && $sz -le $((104857600 + 1048576)) ]]; then record "BD-AC-44" PASS "restic backup of 200 MiB exit $rc; du -sb repos = $sz <= 105906176 ($(cut -c1-90 <<<"$tail"))"
else record "BD-AC-44" FAIL "rc=$rc size=$sz $tail"; fi
gs 'rm -f /root/rand200'
