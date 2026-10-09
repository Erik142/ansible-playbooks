#!/usr/bin/env python3
"""Maintenance run for one restic repository hosted by the NAS rest-server.

Order: precondition checks, prune guard, verified ``forget`` of explicit IDs,
``prune``, ``check``.

Threat model (BD-A-21, BD-BR-07): a restic client can record any snapshot
time (``restic backup --time``). Retention keyed on that time would let a
client with a forged future time make forget drop all genuine snapshots. The
guard compares each snapshot's recorded time with the modification time of its
file under ``<repo>/snapshots/``, which only the NAS sets. Restic records the
backup start, the file mtime is the upload end, so the check is asymmetric: a
time more than ``--max-skew-hours`` (6) after the mtime, or more than
``--max-past-hours`` (48) before it, is offending. If any snapshot is, the run lists every offending ID,
runs neither forget nor prune, and exits non-zero (BD-FR-114 to BD-FR-116).

The guard result must hold for what is deleted (TOCTOU): a snapshot forged
after the check could otherwise take keep slots in a later ``forget --prune``.
So the policy is evaluated with ``forget --dry-run --json`` and only the IDs it
would remove are passed to ``forget``, and only if every one was in the guarded
snapshot set and the set is unchanged after the dry run. Otherwise the run
exits 3 and deletes nothing.
Recovery after a wrong prune restores with mtime-preserving copies (DOC-O7).

The run never creates a repository (BD-FR-121): a missing ``<repo>/config``
is an error. The repository password comes only from the environment
(``RESTIC_PASSWORD``, set by systemd ``EnvironmentFile=``), never from argv.
The repository location is handed to restic through ``RESTIC_REPOSITORY`` so
argv carries no secret and no path. Needs restic >= 0.16 for ``--retry-lock``.

Exit codes: 0 success, 1 restic step failed, 2 precondition failed,
3 prune guard tripped.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import TextIO

EXIT_OK = 0
EXIT_RESTIC_FAILED = 1
EXIT_PRECONDITION = 2
EXIT_GUARD = 3

_REPO_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
_SNAPSHOT_ID = re.compile(r"[0-9a-f]{64}")
_FRACTION = re.compile(r"\.(\d+)")


class MaintenanceError(Exception):
    """Base class; carries the exit code the run ends with."""

    exit_code = EXIT_PRECONDITION


class PreconditionError(MaintenanceError):
    exit_code = EXIT_PRECONDITION


class ResticError(MaintenanceError):
    exit_code = EXIT_RESTIC_FAILED


class GuardError(MaintenanceError):
    exit_code = EXIT_GUARD


def parse_restic_time(value: str) -> float:
    """Parse a restic RFC 3339 time (nanosecond fraction allowed) to epoch seconds."""
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    # fromisoformat accepts at most 6 fraction digits on older Pythons.
    text = _FRACTION.sub(lambda m: "." + m.group(1)[:6].ljust(6, "0"), text, count=1)
    parsed = datetime.fromisoformat(text)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.timestamp()


def find_skewed_snapshots(
    snapshots: Sequence[Mapping[str, object]],
    snapshots_dir: Path,
    future_skew_seconds: float,
    past_allowance_seconds: float,
) -> list[str]:
    """Return IDs whose recorded time is implausible relative to the file mtime.

    Asymmetric on purpose: restic records the backup START as ``time`` while the
    file mtime is the upload END, so a long backup legitimately has
    ``time < mtime``. Offending are
      * ``time > mtime + future_skew`` (forged future time), and
      * ``mtime - time > past_allowance`` (forged past time or absurdly long run).
    A snapshot with an unusable ID, an unparsable time or a missing file counts
    as offending: the guard cannot vouch for it.
    """
    offending: list[str] = []
    for snap in snapshots:
        snap_id = str(snap.get("id", ""))
        try:
            if not _SNAPSHOT_ID.fullmatch(snap_id):
                raise ValueError("not a 64-hex snapshot ID")
            recorded = parse_restic_time(str(snap["time"]))
            mtime = (snapshots_dir / snap_id).stat().st_mtime
        except (KeyError, ValueError, OSError):
            offending.append(snap_id or "<missing id>")
            continue
        if recorded - mtime > future_skew_seconds or mtime - recorded > past_allowance_seconds:
            offending.append(snap_id)
    return offending


def _snapshot_set(snapshots: Sequence[Mapping[str, object]]) -> frozenset[tuple[str, str]]:
    """Identity of a listing: (id, recorded time) pairs."""
    return frozenset((str(s.get("id", "")), str(s.get("time", ""))) for s in snapshots)


def parse_removed_ids(payload: object) -> list[str]:
    """Extract snapshot IDs from ``forget --dry-run --json`` (list of groups with ``remove``)."""
    if not isinstance(payload, list):
        raise ResticError("restic forget --dry-run JSON is not a list")
    removed: list[str] = []
    for group in payload:
        if not isinstance(group, dict):
            raise ResticError("restic forget --dry-run JSON group is not an object")
        for snap in group.get("remove") or []:
            snap_id = str(snap.get("id", "")) if isinstance(snap, dict) else ""
            if not _SNAPSHOT_ID.fullmatch(snap_id):
                raise ResticError(f"restic forget --dry-run gave an invalid snapshot ID: {snap_id!r}")
            removed.append(snap_id)
    return removed


@dataclass(frozen=True)
class Context:
    """What every restic invocation needs: executable, environment, log stream."""

    restic: str
    env: Mapping[str, str]
    out: TextIO
    retry_lock: str


def _run(cmd: list[str], env: Mapping[str, str], capture: bool = False) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(cmd, env=dict(env), check=False, text=True, stdout=subprocess.PIPE if capture else None)
    except OSError as err:
        raise ResticError(f"cannot run {cmd[0]}: {err}") from err


def _run_step(ctx: Context, name: str, cmd: list[str], capture: bool = False) -> subprocess.CompletedProcess[str]:
    """Announce and run one restic step; a non-zero exit raises ResticError."""
    print(f"running {name}", file=ctx.out, flush=True)
    result = _run(cmd, ctx.env, capture=capture)
    if result.returncode != 0:
        raise ResticError(f"restic {name} exited {result.returncode}")
    return result


def _list_snapshots(ctx: Context) -> list[Mapping[str, object]]:
    listing = _run_step(ctx, "snapshots", [ctx.restic, "snapshots", "--json"], capture=True)
    try:
        snapshots = json.loads(listing.stdout or "[]")
    except json.JSONDecodeError as err:
        raise ResticError(f"restic snapshots gave invalid JSON: {err}") from err
    if not isinstance(snapshots, list):
        raise ResticError("restic snapshots JSON is not a list")
    return snapshots


def validate_preconditions(args: argparse.Namespace, env: Mapping[str, str]) -> Path:
    """Check name, password and repository presence; return the repository path."""
    if not _REPO_NAME.fullmatch(args.repo):
        raise PreconditionError(f"invalid repository name: {args.repo!r}")
    if not env.get("RESTIC_PASSWORD"):
        raise PreconditionError("RESTIC_PASSWORD is not set in the environment")
    repo = Path(args.repo_root) / args.repo
    if not (repo / "config").is_file():
        raise PreconditionError(f"repository missing, not creating one: {repo}")
    return repo


def check_prune_guard(ctx: Context, args: argparse.Namespace, repo: Path) -> frozenset[tuple[str, str]]:
    """Run the time guard; return the guarded snapshot set or raise GuardError."""
    snapshots = _list_snapshots(ctx)
    offending = find_skewed_snapshots(
        snapshots, repo / "snapshots", args.max_skew_hours * 3600, args.max_past_hours * 3600
    )
    if offending:
        print(
            f"prune guard: {len(offending)} snapshot(s) with recorded time more than "
            f"{args.max_skew_hours} h after or {args.max_past_hours} h before file mtime; "
            "no forget, no prune:",
            file=ctx.out,
        )
        for snap_id in offending:
            print(f"  offending snapshot {snap_id}", file=ctx.out)
        raise GuardError("prune guard tripped")
    return _snapshot_set(snapshots)


def plan_removals(ctx: Context, args: argparse.Namespace, guarded: frozenset[tuple[str, str]]) -> list[str]:
    """Evaluate the policy once (dry run); return the verified IDs to forget.

    Raises GuardError if the removal set holds an ID the guard did not see or
    the snapshot list changed since the guard (TOCTOU).
    """
    dry = _run_step(
        ctx,
        "forget --dry-run",
        [
            ctx.restic, "forget", "--dry-run", "--json",
            "--keep-daily", str(args.keep_daily),
            "--keep-weekly", str(args.keep_weekly),
            "--keep-monthly", str(args.keep_monthly),
            "--retry-lock", ctx.retry_lock,
        ],
        capture=True,
    )  # fmt: skip
    try:
        to_remove = parse_removed_ids(json.loads(dry.stdout or "[]"))
    except json.JSONDecodeError as err:
        raise ResticError(f"restic forget --dry-run gave invalid JSON: {err}") from err

    known = {snap_id for snap_id, _ in guarded}
    unknown = sorted(set(to_remove) - known)
    changed = _snapshot_set(_list_snapshots(ctx)) != guarded
    if unknown or changed:
        print("prune guard: repository changed during the run; no forget, no prune:", file=ctx.out)
        for snap_id in unknown:
            print(f"  unverified snapshot in removal set {snap_id}", file=ctx.out)
        if changed:
            print("  snapshot list differs from the guarded list", file=ctx.out)
        raise GuardError("prune guard tripped: snapshot set changed between check and forget")
    removals = sorted(set(to_remove))
    print(
        f"retention policy: keep {args.keep_daily} daily, {args.keep_weekly} weekly, "
        f"{args.keep_monthly} monthly snapshots; forgetting {len(removals)} verified snapshot(s)"
        + (": " + " ".join(removals) if removals else ""),
        file=ctx.out,
        flush=True,
    )
    return removals


def execute_steps(ctx: Context, args: argparse.Namespace, removals: Sequence[str]) -> None:
    """Forget the explicit IDs (if any), prune, then check."""
    lock = ["--retry-lock", ctx.retry_lock]
    steps: list[tuple[str, list[str]]] = []
    if removals:
        steps.append(("forget", [ctx.restic, "forget", *removals, *lock]))
    steps.append(("prune", [ctx.restic, "prune", *lock]))
    steps.append(("check", [ctx.restic, "check", f"--read-data-subset={args.check_subset}", *lock]))
    for name, cmd in steps:
        _run_step(ctx, name, cmd)


def run_maintenance(args: argparse.Namespace, env: Mapping[str, str], out: TextIO) -> None:
    """Run the maintenance steps; raise a MaintenanceError on any failure."""
    repo = validate_preconditions(args, env)
    ctx = Context(args.restic, {**env, "RESTIC_REPOSITORY": str(repo)}, out, args.retry_lock)
    guarded = check_prune_guard(ctx, args, repo)
    removals = plan_removals(ctx, args, guarded)
    execute_steps(ctx, args, removals)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="restic repository maintenance with prune guard")
    p.add_argument("--repo-root", required=True, help="restic_server_data_dir")
    p.add_argument("--repo", required=True, help="repository directory name below the root")
    p.add_argument("--keep-daily", type=int, default=7)
    p.add_argument("--keep-weekly", type=int, default=4)
    p.add_argument("--keep-monthly", type=int, default=6)
    p.add_argument("--check-subset", default="10%")
    p.add_argument("--retry-lock", default="30m")
    p.add_argument("--max-skew-hours", type=float, default=6.0, help="allowed snapshot time ahead of file mtime")
    p.add_argument(
        "--max-past-hours", type=float, default=48.0, help="allowed snapshot time behind file mtime (long backups)"
    )
    p.add_argument("--restic", default="restic", help="restic executable")
    return p


def main(
    argv: Sequence[str] | None = None,
    env: Mapping[str, str] | None = None,
    out: TextIO | None = None,
    err: TextIO | None = None,
) -> int:
    out = out if out is not None else sys.stdout
    err = err if err is not None else sys.stderr
    args = build_parser().parse_args(argv)
    try:
        run_maintenance(args, os.environ if env is None else env, out)
    except MaintenanceError as exc:
        print(f"restic-maintenance: {exc}", file=err)
        return exc.exit_code
    print("restic-maintenance: done", file=out)
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
