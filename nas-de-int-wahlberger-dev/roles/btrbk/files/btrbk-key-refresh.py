#!/usr/bin/python3
# Managed by Ansible (role btrbk). Do NOT edit on the host.
"""Weekly renewal check of the OBS repository signing key (BD-FR-162 to BD-FR-168).

Fetches the key over HTTPS, requires exactly one primary key whose fingerprint
equals the pinned one, then ``rpm --import``s it (an OBS-extended expiry arrives
as a new self-signature on the same key) and proves the repository with
``zypper refresh``. Finally it fails when the fetched key expires in fewer than
``--warn-days`` days, so a key OBS did not extend alerts through OnFailure=.

Exit codes: 0 ok; 1 renewal problem (import/refresh failed or key near expiry);
2 key mismatch (possible rotation or tampering: nothing imported, a human must
verify it, see the role README); 3 key could not be fetched.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from typing import TextIO

EXIT_OK = 0
EXIT_RENEWAL_PROBLEM = 1
EXIT_KEY_MISMATCH = 2
EXIT_FETCH_FAILED = 3
SECONDS_PER_DAY = 86400
FETCH_TIMEOUT_S = 60
FINGERPRINT_RE = re.compile(r"[0-9A-F]{40}")

Runner = Callable[[Sequence[str]], "tuple[int, str]"]


class KeyMismatch(Exception):
    """The fetched key file is not exactly the pinned key."""


@dataclass(frozen=True)
class KeyInfo:
    fingerprint: str
    expires_at: int | None  # epoch seconds; None = key never expires


def run_command(argv: Sequence[str]) -> "tuple[int, str]":
    """Run argv; return (exit status, stdout+stderr). 127 when the binary is missing."""
    try:
        proc = subprocess.run(
            argv, check=False, capture_output=True, text=True, timeout=600
        )
    except FileNotFoundError:
        return 127, f"{argv[0]}: command not found"
    except subprocess.TimeoutExpired:
        return 124, f"{argv[0]}: timed out"
    return proc.returncode, proc.stdout + proc.stderr


def parse_key_info(colons: str) -> KeyInfo:
    """Parse ``gpg --with-colons --with-fingerprint`` output; same rules as install.yml.

    Requires one ``pub`` record and one ``fpr`` per primary key and subkey, so
    a file smuggling in a second key is rejected. The first ``fpr`` is the
    primary key's.
    """
    records = [line.split(":") for line in colons.splitlines() if line]
    pubs = [r for r in records if r[0] == "pub"]
    subs = [r for r in records if r[0] == "sub"]
    fprs = [r for r in records if r[0] == "fpr"]
    if len(pubs) != 1 or len(fprs) != 1 + len(subs):
        raise KeyMismatch(
            f"key file must hold exactly one primary key (found {len(pubs)} pub, "
            f"{len(fprs)} fpr, {len(subs)} sub records)"
        )
    fingerprint = fprs[0][9].upper() if len(fprs[0]) > 9 else ""
    if not FINGERPRINT_RE.fullmatch(fingerprint):
        raise KeyMismatch("primary key fingerprint is missing or malformed")
    expiry_field = pubs[0][6] if len(pubs[0]) > 6 else ""
    if expiry_field == "":
        return KeyInfo(fingerprint, None)
    if not expiry_field.isdigit():
        raise KeyMismatch(f"unreadable expiry field {expiry_field!r}")
    return KeyInfo(fingerprint, int(expiry_field))


def days_until(expires_at: int | None, now: float) -> int | None:
    """Whole days left (floor; negative once expired); None when it never expires."""
    if expires_at is None:
        return None
    return int((expires_at - now) // SECONDS_PER_DAY)


def refresh_key(
    *,
    url: str,
    fingerprint: str,
    alias: str,
    warn_days: int,
    run: Runner,
    now: Callable[[], float],
    out: TextIO,
) -> int:
    """Fetch, verify, import, refresh, check expiry. Returns the process exit code."""
    pinned = fingerprint.upper()
    if not url.startswith("https://"):
        print(f"btrbk-key-refresh: key URL must be https, got {url!r}", file=out)
        return EXIT_FETCH_FAILED
    with tempfile.TemporaryDirectory(prefix="btrbk-key-") as scratch:
        key_file = os.path.join(scratch, "repo.key")
        status, text = run(
            [
                "curl", "--fail", "--silent", "--show-error", "--location",
                "--proto", "=https", "--max-time", str(FETCH_TIMEOUT_S),
                "--output", key_file, url,
            ]
        )  # fmt: skip
        if status != 0:
            print(f"btrbk-key-refresh: cannot fetch {url} (exit {status}): {text.strip()}", file=out)
            return EXIT_FETCH_FAILED
        status, text = run(
            ["gpg", "--batch", "--show-keys", "--with-colons", "--with-fingerprint", key_file]
        )
        if status != 0:
            print(f"btrbk-key-refresh: gpg cannot read the key (exit {status}): {text.strip()}", file=out)
            return EXIT_KEY_MISMATCH
        try:
            info = parse_key_info(text)
        except KeyMismatch as err:
            print(f"btrbk-key-refresh: REFUSING TO IMPORT: {err}. Verify by hand.", file=out)
            return EXIT_KEY_MISMATCH
        if info.fingerprint != pinned:
            print(
                f"btrbk-key-refresh: REFUSING TO IMPORT: {url} serves key {info.fingerprint}, "
                f"pinned is {pinned}. Possible key rotation or tampering: verify with "
                "'osc signkey filesystems', then update btrbk_zypper_repo_gpg_fingerprint.",
                file=out,
            )
            return EXIT_KEY_MISMATCH

        problems: list[str] = []
        # Imported even when near expiry: an extended self-signature renews it.
        status, text = run(["rpm", "--import", key_file])
        if status != 0:
            problems.append(f"rpm --import failed (exit {status}): {text.strip()}")
        else:
            print("btrbk-key-refresh: rpm --import ok", file=out)
        status, text = run(["zypper", "--non-interactive", "refresh", alias])
        if status != 0:
            problems.append(f"zypper refresh {alias} failed (exit {status}): {text.strip()}")
        else:
            print(f"btrbk-key-refresh: zypper refresh {alias} ok", file=out)

    days = days_until(info.expires_at, now())
    if days is not None and days < warn_days:
        problems.append(
            f"signing key {pinned} expires in {days} days (< {warn_days}); OBS has not "
            "extended it. Renew by hand, see the btrbk role README."
        )
    if problems:
        for problem in problems:
            print(f"btrbk-key-refresh: {problem}", file=out)
        return EXIT_RENEWAL_PROBLEM
    left = "never expires" if days is None else f"expires in {days} days"
    print(f"btrbk-key-refresh: key {pinned} verified, imported, {alias} refreshed; {left}", file=out)
    return EXIT_OK


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--url", required=True)
    parser.add_argument("--fingerprint", required=True)
    parser.add_argument("--alias", required=True)
    parser.add_argument("--warn-days", type=int, required=True)
    args = parser.parse_args(argv)
    return refresh_key(
        url=args.url, fingerprint=args.fingerprint, alias=args.alias,
        warn_days=args.warn_days, run=run_command, now=time.time, out=sys.stdout,
    )  # fmt: skip


if __name__ == "__main__":
    sys.exit(main())
