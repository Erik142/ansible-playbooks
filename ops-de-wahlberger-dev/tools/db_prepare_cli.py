#!/usr/bin/env python3
"""CLI behind db-prepare.sh."""

from __future__ import annotations

import sys

from db_prepare import PrepareError, prepare


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: db_prepare_cli.py <database-copy>", file=sys.stderr)
        return 2
    try:
        report = prepare(argv[1])
    except PrepareError as err:
        print(f"db-prepare: FAILED: {err}", file=sys.stderr)
        return 1
    print("\n".join(report.lines()))
    print("db-prepare: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
