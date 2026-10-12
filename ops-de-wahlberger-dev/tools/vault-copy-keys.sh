#!/usr/bin/env bash
# Copy Vault values into DIFFERENTLY-NAMED keys of another existing vault file.
# Usage: vault-copy-keys.sh <src-vault.yml>:<src-key>=<dst-key> ... --to <dst-vault.yml>
#                           [--dry-run] [--force]
#        vault-copy-keys.sh --ops-to-nas [--dry-run] [--force]
# --ops-to-nas copies vault_restic_backup_rest_server_password -> vault_restic_server_ops_htpasswd_password
# and vault_restic_backup_repo_password -> vault_restic_server_ops_repo_password (ops -> NAS).
# New keys are appended to the destination plaintext (nothing else is rewritten); an existing
# key with an equal value is left alone, a different one needs --force. After writing, the
# destination is re-read and every value compared by SHA-256; a MISMATCH restores the old file.
# Prints "<dst-key>: copied, match|MISMATCH" / "already present, equal"; never a value or hash.
# Optional env: VAULT_SRC_PASS_FILE, VAULT_DST_PASS_FILE (generic mode); VAULT_OPS, VAULT_NAS
#               (vault.yml paths) and VAULT_OPS_PASS_FILE, VAULT_NAS_PASS_FILE (--ops-to-nas).
#               Without a password file each playbook's ansible.cfg supplies the password
#               (.vault_pass.sh: unlock 1Password first).
# Safety: the original encrypted bytes are saved to <vault>.bak (0600) before the write; any
# failure afterwards restores them (verified); the .bak is deleted only after full verification.
# Needs PyYAML (re-executes under ~/.pyenv/versions/ansible-bind9-venv/bin/python if python3
# lacks it; VAULT_COPY_PYTHON overrides the interpreter). Password files must not be executable.
# Exit 0 ok, 1 vault modified then restored (MISMATCH/failure), 2 error/usage/refused (nothing
# written), 3 restore FAILED (message gives the recovery command).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${VAULT_COPY_PYTHON:-python3}" "$here/vault_copy_cli.py" "$@"
