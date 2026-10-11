#!/usr/bin/env bash
# Compare two DIFFERENTLY-NAMED Vault keys across two vault files by SHA-256.
# Usage: vault-pair-compare.sh <vault.yml>:<key> <vault.yml>:<key> [label]
#        vault-pair-compare.sh --cloud-nas      (restic REST password, cloud <-> NAS)
# Each side is split on its LAST colon (a path may contain colons, a key never does).
# Prints "<label>: match" or "<label>: MISMATCH" and nothing else (no values, no hashes).
# Optional env: VAULT_LEFT_PASS_FILE, VAULT_RIGHT_PASS_FILE (pair mode);
#               VAULT_CLOUD, VAULT_NAS (vault.yml paths) and VAULT_CLOUD_PASS_FILE,
#               VAULT_NAS_PASS_FILE (--cloud-nas). Without a password file each playbook's
#               ansible.cfg supplies the password (.vault_pass.sh: unlock 1Password first).
# Exit 0 match, 1 MISMATCH (also a missing key), 2 error/usage.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$here/vault_pair_cli.py" "$@"
