#!/usr/bin/env bash
# Run ansible / ansible-playbook against the VM fixture ONLY.
#   tests/vm/ans.sh ansible-playbook site.yml --tags firewall --check --diff
# Refuses to run unless the fixture host resolves to 127.0.0.1:2223 and the
# throwaway key. Uses tests/vm/ansible.cfg (no vault_password_file, so
# .vault_pass.sh / `op` is never called) and never reads the production vault.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
export ANSIBLE_CONFIG="$PWD/tests/vm/ansible.cfg"
export FIXTURE_VM_DIR="${FIXTURE_VM_DIR:-$HOME/.cache/ops-fixture-vm}"
export PATH="${ANSIBLE_VENV_BIN:-$HOME/.pyenv/versions/ansible-bind9-venv/bin}:$PATH"
INV=(-i inventories/vm/hosts.yml)
out="$(ansible-inventory "${INV[@]}" --host ops-vm-fixture)"
grep -q '"ansible_host": "127.0.0.1"' <<<"$out" && grep -Eq "\"ansible_port\": \"?2223\"?" <<<"$out" ||
  { echo "inventory does not target 127.0.0.1:2223, refusing" >&2; exit 1; }
grep -q "id_fixture" <<<"$out" && ! grep -Eq "ansible_(user|host)\"?: \"(erikwahlberger|ops\.)" <<<"$out" ||
  { echo "inventory does not use the fixture key/user, refusing" >&2; exit 1; }
# Only this host may be addressed.
[[ "$(ansible-inventory "${INV[@]}" --list | grep -c '"ops-vm-fixture"')" -ge 1 ]] || { echo "fixture host missing" >&2; exit 1; }
tool="$1"; shift
# Production NON-secret vars (vars.yml only, minus keys the fixture overrides) so
# argument specs of the roles validate. Secrets come from the fixture inventory.
PV="$FIXTURE_VM_DIR/prod-vars.yml"
python3 tests/vm/gen-prod-vars.py "$PV"
exec "$tool" "${INV[@]}" -e "@$PV" -l ops-vm-fixture "$@"
