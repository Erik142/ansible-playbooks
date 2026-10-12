#!/usr/bin/env python3
"""CLI behind vault-copy-keys.sh (see tools/README.md).

Environment: VAULT_SRC_PASS_FILE, VAULT_DST_PASS_FILE (generic mode); VAULT_OPS, VAULT_NAS,
VAULT_OPS_PASS_FILE, VAULT_NAS_PASS_FILE (--ops-to-nas). All optional.
PyYAML is required: without it the tool re-executes itself under the ansible venv python
(VENV_PYTHON) when that exists, else exits 2.
"""

from __future__ import annotations

import argparse
import os
import signal
import sys
from pathlib import Path

from vault_copy import (
    CopyError,
    CopySpec,
    Refused,
    check_pass_file,
    copy_keys,
    parse_copy_spec,
    playbook_dir,
)
from vault_hash import VaultError

PROG = "vault-copy-keys"
REEXEC_FLAG = "VAULT_COPY_REEXEC"
VENV_PYTHON_REL = Path(".pyenv/versions/ansible-bind9-venv/bin/python")
REPO = Path(__file__).resolve().parents[2]
VAULT_REL = Path("inventories/production/group_vars/all/vault.yml")
OPS_TO_NAS = (
    ("vault_restic_backup_rest_server_password", "vault_restic_server_ops_htpasswd_password"),
    ("vault_restic_backup_repo_password", "vault_restic_server_ops_repo_password"),
)


def _opt_path(name: str) -> Path | None:
    value = os.environ.get(name)
    return Path(value) if value else None


def _announce(side: str, vault: Path, pass_file: Path | None) -> None:
    """One stderr line naming where the vault password comes from (never the password)."""
    if pass_file is not None:
        source = f"password file {pass_file}"
    else:
        source = (
            f"no VAULT_{side.upper()}_PASS_FILE: ansible.cfg of {playbook_dir(vault)} decides "
            "(maybe a script)"
        )
    print(f"{PROG}: {side} vault {vault}: {source}", file=sys.stderr)


def _ensure_pyyaml(argv: list[str]) -> None:
    """Require PyYAML: re-exec under the ansible venv python once, else exit 2."""
    try:
        import yaml  # noqa: F401
    except ImportError:
        venv_python = Path.home() / VENV_PYTHON_REL
        if not os.environ.get(REEXEC_FLAG) and os.access(venv_python, os.X_OK):
            env = {**os.environ, REEXEC_FLAG: "1"}
            os.execve(venv_python, [str(venv_python), str(Path(__file__).resolve()), *argv], env)  # noqa: S606
        print(
            f"{PROG}: PyYAML is required (the safety checks depend on it) but this python "
            f"({sys.executable}) lacks it. Run with the ansible venv python: "
            f"VAULT_COPY_PYTHON={Path.home() / VENV_PYTHON_REL} <this script>",
            file=sys.stderr,
        )
        raise SystemExit(2) from None


def parse_args(argv: list[str]) -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        prog=f"{PROG}.sh",
        description="Copy vault values to differently-named keys of another vault.",
    )
    ap.add_argument("specs", nargs="*", metavar="SRC.yml:SRC_KEY=DST_KEY")
    ap.add_argument("--to", type=Path, metavar="DST.yml", help="the existing destination vault")
    ap.add_argument("--ops-to-nas", action="store_true", help="the two restic copies ops -> NAS")
    ap.add_argument("--dry-run", action="store_true", help="check everything, write nothing")
    ap.add_argument("--force", action="store_true", help="replace an existing, different value")
    args = ap.parse_args(argv)
    if args.ops_to_nas:
        if args.specs or args.to:
            ap.error("--ops-to-nas takes no specs and no --to")
    elif not args.specs or args.to is None:
        ap.error("give at least one spec and --to <dst-vault.yml> (or use --ops-to-nas)")
    return args


def _raise_interrupt(signum: int, _frame: object) -> None:
    """SIGTERM/SIGHUP act like Ctrl-C so the restore-on-BaseException path runs."""
    raise KeyboardInterrupt(signal.Signals(signum).name)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    _ensure_pyyaml(argv)
    signums = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    previous = {n: signal.signal(n, _raise_interrupt) for n in signums}
    try:
        return _run(args)
    except KeyboardInterrupt:
        print(
            f"{PROG}: interrupted before the write phase; the vault was not touched",
            file=sys.stderr,
        )
        return 2
    finally:
        for n, handler in previous.items():
            signal.signal(n, handler)


def _run(args: argparse.Namespace) -> int:
    try:
        if args.ops_to_nas:
            src_side, dst_side = "ops", "nas"
            src = _opt_path("VAULT_OPS") or REPO / "ops-de-wahlberger-dev" / VAULT_REL
            dst = _opt_path("VAULT_NAS") or REPO / "nas-de-int-wahlberger-dev" / VAULT_REL
            specs = [CopySpec(src, s, d) for s, d in OPS_TO_NAS]
        else:
            src_side, dst_side = "src", "dst"
            dst = args.to
            specs = [parse_copy_spec(s) for s in args.specs]
        src_pass = _opt_path(f"VAULT_{src_side.upper()}_PASS_FILE")
        dst_pass = _opt_path(f"VAULT_{dst_side.upper()}_PASS_FILE")
        for vault in dict.fromkeys(s.src_vault for s in specs):
            _announce(src_side, vault, src_pass)
        _announce(dst_side, dst, dst_pass)
        for pass_file in (src_pass, dst_pass):
            check_pass_file(pass_file)
        return copy_keys(
            specs, dst, src_pass=src_pass, dst_pass=dst_pass, dry_run=args.dry_run, force=args.force
        )
    except Refused as exc:
        print(f"{PROG}: REFUSED: {exc}", file=sys.stderr)
        return 2
    except (CopyError, VaultError, OSError) as exc:
        print(f"{PROG}: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
