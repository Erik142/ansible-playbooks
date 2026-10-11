#!/usr/bin/env bash
# Compare Vault keys between the Pi vault and the VM vault by SHA-256 (SH-AC-17).
# Usage: vault-hash-compare.sh <vault-key>...
# Prints "<key>: match" or "<key>: MISMATCH" and nothing else (no values, no hashes).
# Optional env: VAULT_PI, VAULT_VM (vault.yml paths; default: this repo's two vaults),
#               VAULT_PI_PASS_FILE, VAULT_VM_PASS_FILE (else each playbook's ansible.cfg
#               supplies the password, e.g. .vault_pass.sh, which needs 1Password unlocked).
# Exit 0 all match, 1 any MISMATCH, 2 error/usage.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$here/vault_hash_cli.py" "$@"
