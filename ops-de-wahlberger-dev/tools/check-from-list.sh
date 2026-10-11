#!/usr/bin/env bash
# Verify the new automation key line in nas, cloud and the VM playbook (SH-AC-23, SH-FR-126).
# Usage: check-from-list.sh <repo> --vm-public-ip <ip> [--vm-zt-ip <ip>] [--sem-subnet <cidr>] [--extra <addr>]...
# --vm-public-ip may also come from VM_PUBLIC_IP; the other two default to the VM vars.yml.
# Exit 0 ok, 1 check failed, 2 usage/input error.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$here/check_from_list_cli.py" "$@"
