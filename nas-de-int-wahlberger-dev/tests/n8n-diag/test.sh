#!/usr/bin/env bash
# Tests roles/n8n/files/n8n-diag-bundle.sh with stubbed systemctl/journalctl.
# Checks: an allowlisted unit is printed; anything else is refused with exit 2;
# output is capped. Runs without root and without systemd.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$HERE/../../roles/n8n/files/n8n-diag-bundle.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

mkdir -p "$work/bin"
cat >"$work/bin/systemctl" <<'STUB'
#!/bin/bash
echo "STUB systemctl $*"
STUB
cat >"$work/bin/journalctl" <<'STUB'
#!/bin/bash
for i in $(seq 1 500); do echo "STUB journal line $i"; done
STUB
chmod +x "$work/bin/"*
printf 'caddy.service\nn8n.service\n' >"$work/units"

run() { # <unit-or-arg> -> sets out, rc
    set +e
    out=$(PATH="$work/bin:$PATH" N8N_DIAG_UNITS_FILE="$work/units" SSH_ORIGINAL_COMMAND="$1" bash "$SCRIPT" 2>"$work/err")
    rc=$?
    set -e
}

check() { # name expected-rc actual-rc
    if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: expected rc $2, got $3"; fail=1; fi
}

run n8n.service
check "allowlisted unit is printed" 0 "$rc"
grep -q "STUB systemctl" <<<"$out" || { echo "FAIL allowlisted unit: no status output"; fail=1; }

run "forgejo.service"
check "unit not on the allowlist is refused" 2 "$rc"

run "n8n.service; id"
check "shell metacharacters are refused" 2 "$rc"

run "cd / ; n8n.service"
check "the n8n SSH node's cd prefix is accepted" 0 "$rc"

run "cd / ; id ; n8n.service"
check "a cd prefix with a second command is refused" 2 "$rc"

run "cd /;id ; n8n.service"
check "a cd prefix without spaces is refused" 2 "$rc"

run "cd / && n8n.service"
check "an && prefix (not what node-ssh sends) is refused" 2 "$rc"

run "n8n.service --help"
check "extra arguments are refused" 2 "$rc"

run ""
check "empty command is refused" 2 "$rc"

run "caddy.service"
size=$(printf '%s' "$out" | wc -c)
if [ "$size" -le 8192 ]; then echo "PASS output capped at 8 KiB ($size bytes)"; else echo "FAIL output not capped ($size bytes)"; fail=1; fi

if [ "$fail" = 0 ]; then echo "ALL PASS: n8n-diag-bundle"; else echo "FAILURES: n8n-diag-bundle"; fi
exit "$fail"
