#!/bin/bash
# Forced command for the n8n-diag SSH key (roles/n8n). The client sends one unit name;
# the script prints a short diagnostic bundle for that unit. Anything not on the
# allowlist (UNITS_FILE, one unit per line) is refused. No arguments, no shell.
set -eu

UNITS_FILE=${N8N_DIAG_UNITS_FILE:-/etc/n8n-diag/units}
MAX_BYTES=${N8N_DIAG_MAX_BYTES:-8192}

unit=${SSH_ORIGINAL_COMMAND:-${1:-}}

# The n8n SSH node (node-ssh) sends "cd <cwd> ; <unit>". Accept that prefix only; the unit name is
# still checked below, so nothing else can ride along.
if [[ "$unit" =~ ^cd\ ([A-Za-z0-9/._~-]+)\ \;\ (.+)$ ]]; then
    unit=${BASH_REMATCH[2]}
fi

case "$unit" in
    "" | *[!A-Za-z0-9@._-]*)
        echo "refused: invalid unit name" >&2
        exit 2
        ;;
esac

if ! grep -qxF -- "$unit" "$UNITS_FILE"; then
    echo "refused: $unit is not in the allowlist" >&2
    exit 2
fi

{
    echo "== systemctl status $unit"
    systemctl status --no-pager --lines=0 "$unit" || true
    echo "== journal (last 200 lines)"
    journalctl -u "$unit" -n 200 --no-pager || true
} | head -c "$MAX_BYTES"
