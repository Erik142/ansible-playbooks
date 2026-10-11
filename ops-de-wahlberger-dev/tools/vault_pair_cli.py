#!/usr/bin/env python3
"""CLI behind vault-pair-compare.sh: one key per vault, names may differ.

Environment: VAULT_LEFT_PASS_FILE, VAULT_RIGHT_PASS_FILE (pair mode); VAULT_CLOUD, VAULT_NAS,
VAULT_CLOUD_PASS_FILE, VAULT_NAS_PASS_FILE (--cloud-nas). All optional.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

from vault_hash import (
    MATCH,
    MISMATCH,
    VaultError,
    _digest,
    parse_top_level,
    view_with_ansible_vault,
)

PROG = "vault-pair-compare"
USAGE = (
    f"usage: {PROG}.sh <vault.yml>:<key> <vault.yml>:<key> [label]\n       {PROG}.sh --cloud-nas"
)
REPO = Path(__file__).resolve().parents[2]
VAULT_REL = Path("inventories/production/group_vars/all/vault.yml")
CLOUD_KEY = "vault_restic_backup_rest_server_password"
NAS_KEY = "vault_restic_server_cloud_htpasswd_password"
CLOUD_NAS_LABEL = "restic_rest_password"


def _opt_path(name: str) -> Path | None:
    value = os.environ.get(name)
    return Path(value) if value else None


def parse_spec(spec: str) -> tuple[Path, str]:
    """Split ``<path>:<key>`` on the last colon."""
    path, sep, key = spec.rpartition(":")
    if not sep or not path or not key:
        raise VaultError(f"expected <vault.yml>:<key>, got {spec!r}")
    return Path(path), key


def _announce(side: str, vault: Path, pass_file: Path | None) -> None:
    """One stderr line naming where the vault password comes from (never the password)."""
    if pass_file is not None:
        source = f"password file {pass_file}"
    else:
        # <playbook>/inventories/production/group_vars/all/vault.yml -> parents[4] is <playbook>
        cwd = vault.parents[4] if len(vault.parents) > 4 else vault.parent
        source = f"no VAULT_{side.upper()}_PASS_FILE: ansible.cfg of {cwd} decides (maybe a script)"
    print(f"{PROG}: {side} vault {vault}: {source}", file=sys.stderr)


def compare_pair(
    left: dict[str, str], left_key: str, right: dict[str, str], right_key: str
) -> tuple[str, list[str]]:
    """Return ``(verdict, sides missing the key)``; a missing key is always a MISMATCH."""
    missing = [
        side
        for side, data, key in (("left", left, left_key), ("right", right, right_key))
        if key not in data
    ]
    if missing:
        return MISMATCH, missing
    return (MATCH if _digest(left[left_key]) == _digest(right[right_key]) else MISMATCH), []


def main(argv: list[str]) -> int:
    args = argv[1:]
    try:
        if args == ["--cloud-nas"]:
            sides = ("cloud", "nas")
            lvault = _opt_path("VAULT_CLOUD") or REPO / "cloud-wahlberger-dev" / VAULT_REL
            rvault = _opt_path("VAULT_NAS") or REPO / "nas-de-int-wahlberger-dev" / VAULT_REL
            lkey, rkey, label = CLOUD_KEY, NAS_KEY, CLOUD_NAS_LABEL
        elif len(args) in (2, 3) and not args[0].startswith("--"):
            sides = ("left", "right")
            lvault, lkey = parse_spec(args[0])
            rvault, rkey = parse_spec(args[1])
            label = args[2] if len(args) == 3 else f"{lkey} vs {rkey}"
        else:
            print(USAGE, file=sys.stderr)
            return 2
        passes = [_opt_path(f"VAULT_{s.upper()}_PASS_FILE") for s in sides]
        _announce(sides[0], lvault, passes[0])
        _announce(sides[1], rvault, passes[1])
        left = parse_top_level(view_with_ansible_vault(lvault, passes[0]))
        right = parse_top_level(view_with_ansible_vault(rvault, passes[1]))
    except VaultError as err:
        print(f"{PROG}: {err}", file=sys.stderr)
        return 2
    verdict, missing = compare_pair(left, lkey, right, rkey)
    print(f"{label}: {verdict}")
    if missing:
        names = ",".join(sides[0 if m == "left" else 1] for m in missing)
        print(f"{PROG}: {label}: missing in {names}", file=sys.stderr)
    return 0 if verdict == MATCH else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
