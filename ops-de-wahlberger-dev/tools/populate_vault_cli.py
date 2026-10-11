#!/usr/bin/env python3
"""CLI behind populate-vault.sh (see tools/README.md for the operator commands)."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from populate_vault import Options, PopulateError, Refused, populate
from vault_hash import VaultError

OPS_DIR = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = Path(__file__).resolve().parent / "vault-manifest.yml"


def parse_args(argv: list[str]) -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        prog="populate-vault.sh",
        description="Build the VM vault.yml from tools/vault-manifest.yml; prints no value.",
    )
    ap.add_argument("--force", action="store_true", help="rebuild an existing real vault.yml")
    ap.add_argument(
        "--replace-placeholder",
        action="store_true",
        help="replace a vault.yml that the VM password cannot decrypt (the throwaway placeholder)",
    )
    ap.add_argument(
        "--regenerate-secrets",
        action="store_true",
        help="with --force: also draw NEW generated passwords (default keeps the existing ones)",
    )
    ap.add_argument(
        "--show-hash", action="store_true", help="print sha256 first-8 hex per key (default off)"
    )
    ap.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    ap.add_argument("--ops-dir", type=Path, default=OPS_DIR, help="the VM playbook dir (target)")
    ap.add_argument(
        "--repo-root", type=Path, default=None, help="dir holding the pi/cloud/nas playbook dirs"
    )
    return ap.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    ops_dir = args.ops_dir.resolve()
    opts = Options(
        manifest=args.manifest,
        ops_dir=ops_dir,
        repo_root=(args.repo_root or ops_dir.parent).resolve(),
        force=args.force,
        replace_placeholder=args.replace_placeholder,
        regenerate_secrets=args.regenerate_secrets,
        show_hash=args.show_hash,
    )
    try:
        return populate(opts)
    except Refused as err:
        print(f"populate-vault: REFUSED: {err}", file=sys.stderr)
        return 3
    except (PopulateError, VaultError, OSError) as err:
        print(f"populate-vault: {err}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
