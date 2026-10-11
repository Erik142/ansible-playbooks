#!/usr/bin/env bash
# Build the VM's real vault.yml (operator-run, 1Password unlocked). See tools/README.md.
# Usage: populate-vault.sh [--replace-placeholder] [--force] [--regenerate-secrets]
#                          [--show-hash] [--manifest F] [--ops-dir D] [--repo-root D]
# Prints key names, copied/generated/kept and match/MISMATCH; never a value.
# Exit 0 all verified, 1 MISMATCH/format failure, 2 error, 3 refused to overwrite.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$here/populate_vault_cli.py" "$@"
