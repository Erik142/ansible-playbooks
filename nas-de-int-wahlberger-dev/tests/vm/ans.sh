#!/usr/bin/env bash
# Run ansible / ansible-playbook against the VM fixture ONLY.
#   tests/vm/ans.sh ansible-playbook site.yml --tags backup_disk -e ...
# Refuses to run unless the fixture host resolves to 127.0.0.1:2222.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
export ANSIBLE_CONFIG="$PWD/tests/vm/ansible.cfg"
export PATH="${ANSIBLE_VENV_BIN:-$HOME/.pyenv/versions/ansible-bind9-venv/bin}:$PATH"
INV=(-i inventories/vm -i tests/vm/inventory.yml)
out="$(ansible-inventory "${INV[@]}" --host nas-vm-fixture)"
grep -q '"ansible_host": "127.0.0.1"' <<<"$out" && grep -Eq "\"ansible_port\": \"?2222\"?" <<<"$out" ||
  { echo "inventory does not target 127.0.0.1:2222, refusing" >&2; exit 1; }
tool="$1"; shift
# Production NON-secret vars (minus keys the fixture overrides) so unrelated
# roles' argument specs validate; secrets stay empty (vars.yml defaults them).
PV="${FIXTURE_VM_DIR:-$HOME/.cache/nas-fixture-vm}/prod-vars.yml"
python3 tests/vm/gen-prod-vars.py "$PV"
exec "$tool" "${INV[@]}" -e "@$PV" "$@"
