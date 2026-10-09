#!/usr/bin/env bash
# Apply the roles of the backup stack to the VM (real run). Extra args pass through.
#   tests/vm/stack.sh [-e k=v ...] [--check]
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
FIXTURE_VM_DIR="${FIXTURE_VM_DIR:-$HOME/.cache/nas-fixture-vm}"
U=$(cat "$FIXTURE_VM_DIR/backup_uuid")
exec tests/vm/ans.sh ansible-playbook site.yml \
  --tags notify_failure,disk_space,smartd,backup_disk,firewall,storage,snapper,podman,restic_server,db_dump,btrbk,restic_backup_decommission \
  -e "backup_disk_uuid=$U" "$@" </dev/null
