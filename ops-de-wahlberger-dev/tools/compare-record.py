#!/usr/bin/env python3
"""Compare a step-4 record with a Semaphore instance (SH-AC-20, run before any VM task).

Usage: SEMAPHORE_USER=... SEMAPHORE_PASSWORD=... compare-record.py <record.json> <vm-url>
Fails when any count or the newest task id differs, or any VM schedule is active.
Exit codes: 0 equal, 1 differs (each difference printed), 2 usage/credential/API error.
"""

from __future__ import annotations

import sys

from semaphore_record import (
    SemaphoreClient,
    SemaphoreError,
    build_record,
    compare_records,
    credentials_from_env,
    load_record,
)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        recorded = load_record(argv[1])
        user, password = credentials_from_env()
        client = SemaphoreClient(argv[2])
        client.login(user, password)
        current = build_record(client)
    except SemaphoreError as err:
        print(f"compare-record: {err}", file=sys.stderr)
        return 2
    if recorded.get("semaphore_version") != current["semaphore_version"]:
        print(
            f"WARN version: record={recorded.get('semaphore_version')} "
            f"vm={current['semaphore_version']}",
            file=sys.stderr,
        )
    diffs = compare_records(recorded, current)
    for diff in diffs:
        print(diff)
    if diffs:
        return 1
    print("OK counts, newest task id and schedules match the record")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
