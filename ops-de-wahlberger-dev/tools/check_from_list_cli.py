#!/usr/bin/env python3
"""CLI behind check-from-list.sh."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from check_from_list import CheckError, check


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="check-from-list.sh")
    ap.add_argument("repo", type=Path, help="repository root")
    ap.add_argument("--vm-public-ip", default=os.environ.get("VM_PUBLIC_IP"))
    ap.add_argument("--vm-zt-ip", help="default: vm_zt_ip from the VM vars.yml")
    ap.add_argument("--sem-subnet", help="default: semaphore_network_subnet from the VM vars.yml")
    ap.add_argument("--extra", action="append", default=[], help="SH-FR-191 address (repeatable)")
    args = ap.parse_args(argv[1:])
    if not args.vm_public_ip:
        print("check-from-list: --vm-public-ip (or VM_PUBLIC_IP) is required", file=sys.stderr)
        return 2
    try:
        result = check(
            args.repo, args.vm_public_ip, args.vm_zt_ip, args.sem_subnet, tuple(args.extra)
        )
    except CheckError as err:
        print(f"check-from-list: {err}", file=sys.stderr)
        return 2
    for problem in result.problems:
        print(f"FAIL {problem}")
    if result.ok:
        print("OK new key line identical in nas, cloud and the VM playbook; from= as expected")
    return 0 if result.ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
