"""Fixtures: a fake restic executable and a temp repository with controlled mtimes."""

from __future__ import annotations

import importlib.util
import json
import os
import stat
import sys
from dataclasses import dataclass
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "roles/restic_server/files/restic-maintenance.py"

FAKE_RESTIC = """#!{python}
import json, os, sys
log = os.environ["FAKE_RESTIC_LOG"]
with open(log, "a") as fh:
    fh.write(json.dumps({{"argv": sys.argv[1:], "env": dict(os.environ)}}) + "\\n")
cmd = sys.argv[1]
name = cmd.upper()
if cmd == "snapshots":
    n = sum(1 for l in open(log) if json.loads(l)["argv"][0] == "snapshots")
    # FAKE_RESTIC_SNAPSHOTS_2 simulates a snapshot appearing after the first listing.
    first = os.environ["FAKE_RESTIC_SNAPSHOTS"]
    sys.stdout.write(os.environ.get("FAKE_RESTIC_SNAPSHOTS_2", first) if n >= 2 else first)
elif cmd == "forget" and "--dry-run" in sys.argv:
    name = "DRYRUN"
    sys.stdout.write(os.environ["FAKE_RESTIC_DRYRUN"])
sys.exit(int(os.environ.get("FAKE_RESTIC_FAIL_" + name, "0")))
"""


@pytest.fixture(scope="session")
def script_module():
    spec = importlib.util.spec_from_file_location("restic_maintenance", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules["restic_maintenance"] = module
    spec.loader.exec_module(module)
    return module


@dataclass
class Env:
    root: Path
    repo: Path
    restic: Path
    log: Path
    base_time: float
    environ: dict[str, str]

    def add_snapshot(self, sid: str, recorded_offset_s: float, mtime_offset_s: float = 0.0) -> dict:
        """Create snapshots/<sid> with mtime base+mtime_offset; return its JSON entry."""
        from datetime import datetime, timezone

        path = self.repo / "snapshots" / sid
        path.write_text("x")
        os.utime(path, (self.base_time + mtime_offset_s, self.base_time + mtime_offset_s))
        stamp = datetime.fromtimestamp(self.base_time + recorded_offset_s, timezone.utc)
        return {"id": sid, "time": stamp.strftime("%Y-%m-%dT%H:%M:%S.000000000Z")}

    def set_snapshots(self, entries: list[dict]) -> None:
        self.environ["FAKE_RESTIC_SNAPSHOTS"] = json.dumps(entries)

    def set_dry_run_removals(self, ids: list[str]) -> None:
        """Make `forget --dry-run --json` report these IDs as to-be-removed."""
        group = {"keep": [], "remove": [{"id": i} for i in ids]}
        self.environ["FAKE_RESTIC_DRYRUN"] = json.dumps([group])

    def calls(self) -> list[dict]:
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def argvs(self) -> list[list[str]]:
        return [c["argv"] for c in self.calls()]


@pytest.fixture
def env(tmp_path: Path) -> Env:
    root = tmp_path / "repos"
    repo = root / "cloud"
    (repo / "snapshots").mkdir(parents=True)
    (repo / "config").write_text("cfg")
    restic = tmp_path / "restic"
    restic.write_text(FAKE_RESTIC.format(python=sys.executable))
    restic.chmod(restic.stat().st_mode | stat.S_IXUSR)
    log = tmp_path / "calls.jsonl"
    environ = {
        "PATH": os.environ.get("PATH", ""),
        "RESTIC_PASSWORD": "s3cret-pw-for-tests",
        "FAKE_RESTIC_LOG": str(log),
        "FAKE_RESTIC_SNAPSHOTS": "[]",
        "FAKE_RESTIC_DRYRUN": "[]",
    }
    return Env(root, repo, restic, log, 1_800_000_000.0, environ)
