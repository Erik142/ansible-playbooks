#!/bin/sh
# Run one molecule scenario (test sequence) under collections/homelab/extensions.
# Renders the real non-secret group_vars first, so playbook scenarios see the same
# values as the host inventories. Used locally and by the CI molecule job.
#
# Usage: scripts/molecule.sh <scenario> [molecule test args...]
set -eu

if [ $# -lt 1 ]; then
	echo "usage: $0 <scenario> [molecule test args...]" >&2
	exit 2
fi
scenario=$1
shift

if ! python3 -c 'import yaml' 2>/dev/null; then
	echo "molecule.sh: PyYAML missing. Install the CI tooling: pip install -r requirements-ci.txt" >&2
	exit 1
fi

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"

python3 scripts/molecule-inventory.py

cd collections/homelab/extensions
exec molecule test -s "$scenario" "$@"
