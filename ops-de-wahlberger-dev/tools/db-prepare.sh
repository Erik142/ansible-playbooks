#!/usr/bin/env bash
# Prepare a workstation COPY of Semaphore's database.sqlite for the VM (step 4).
# Usage: db-prepare.sh <path-to-copy>
# Checkpoints the WAL, checks integrity, sets all schedules inactive, asserts no
# -wal/-shm/-journal remains, and lists keys, tokens, integrations and Pi-specific
# matches by name only. Exit 0 ok, 1 unusable copy, 2 usage.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <path-to-database-copy>" >&2
  exit 2
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$here/db_prepare_cli.py" "$1"
