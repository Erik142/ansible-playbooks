#!/usr/bin/env python3
"""Print the step-4 record of a Semaphore instance as JSON (read-only GETs).

Usage: SEMAPHORE_USER=... SEMAPHORE_PASSWORD=... step4-record.py <base-url>
Credentials are read from the environment and never printed.
Exit codes: 0 ok, 2 usage/credential/API error.
"""

from __future__ import annotations

import json
import sys

from semaphore_record import SemaphoreClient, SemaphoreError, build_record, credentials_from_env


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        user, password = credentials_from_env()
        client = SemaphoreClient(argv[1])
        client.login(user, password)
        record = build_record(client)
    except SemaphoreError as err:
        print(f"step4-record: {err}", file=sys.stderr)
        return 2
    json.dump(record, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
