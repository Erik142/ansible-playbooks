#!/usr/bin/env python3
"""CLI behind vault-hash-compare.sh. Environment: VAULT_PI, VAULT_VM (paths),
VAULT_PI_PASS_FILE, VAULT_VM_PASS_FILE (optional)."""

from __future__ import annotations

import os
import sys
from pathlib import Path

from vault_hash import MATCH, VaultError, run

REPO = Path(__file__).resolve().parents[2]
VAULT_REL = Path("inventories/production/group_vars/all/vault.yml")


def _opt_path(name: str) -> Path | None:
    value = os.environ.get(name)
    return Path(value) if value else None


def _announce(side: str, vault: Path, pass_file: Path | None) -> None:
    """One stderr line naming where the vault password comes from (never the password)."""
    if pass_file is not None:
        source = f"password file {pass_file}"
    else:
        # <playbook>/inventories/production/group_vars/all/vault.yml -> parents[4] is <playbook>
        cwd = vault.parents[4] if len(vault.parents) > 4 else vault.parent
        source = f"no VAULT_{side.upper()}_PASS_FILE: ansible.cfg of {cwd} decides (maybe a script)"
    print(f"vault-hash-compare: {side} vault {vault}: {source}", file=sys.stderr)


def main(argv: list[str]) -> int:
    keys = argv[1:]
    if not keys:
        print("usage: vault-hash-compare.sh <vault-key>...", file=sys.stderr)
        return 2
    pi_vault = _opt_path("VAULT_PI") or REPO / "pi-de-int-wahlberger-dev" / VAULT_REL
    vm_vault = _opt_path("VAULT_VM") or REPO / "ops-de-wahlberger-dev" / VAULT_REL
    _announce("pi", pi_vault, _opt_path("VAULT_PI_PASS_FILE"))
    _announce("vm", vm_vault, _opt_path("VAULT_VM_PASS_FILE"))
    try:
        results = run(
            keys,
            pi_vault,
            vm_vault,
            _opt_path("VAULT_PI_PASS_FILE"),
            _opt_path("VAULT_VM_PASS_FILE"),
        )
    except VaultError as err:
        print(f"vault-hash-compare: {err}", file=sys.stderr)
        return 2
    for key, verdict, note in results:
        print(f"{key}: {verdict}")
        if note:
            print(f"vault-hash-compare: {key}: {note}", file=sys.stderr)
    return 0 if all(verdict == MATCH for _, verdict, _ in results) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
