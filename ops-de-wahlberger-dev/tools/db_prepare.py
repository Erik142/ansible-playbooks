"""Prepare a workstation copy of Semaphore's SQLite database for the VM.

Steps (SH-FR-49, 54, 177, 178, 179, 203, 204):
  1. ``PRAGMA wal_checkpoint(TRUNCATE)`` (a -wal copied beside the file is merged),
  2. ``PRAGMA integrity_check`` must return ``ok``,
  3. every schedule is set inactive,
  4. checkpoint again, leave WAL mode, then no ``-wal`` / ``-shm`` / ``-journal`` file may remain,
  5. list access keys, API tokens, integrations and Pi-specific matches BY NAME.

Secret columns are never printed: a match is reported as table.column plus the
row's ``name`` (or a row count when the table has no name column). The primary
key of ``user__token`` is the token itself and is never printed.
"""

from __future__ import annotations

import re
import shutil
import sqlite3
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import quote

PI_PATTERN = re.compile(r"pi\.de\.int\.wahlberger\.dev|pi-de-int-wahlberger-dev|/mnt/data", re.I)
SIDECAR_SUFFIXES = ("-wal", "-shm", "-journal")


class PrepareError(Exception):
    """The copy cannot be used (exit code 1)."""


@dataclass
class Report:
    schedules_deactivated: int = 0
    keys: list[str] = field(default_factory=list)
    tokens: list[str] = field(default_factory=list)
    integrations: list[str] = field(default_factory=list)
    matches: list[str] = field(default_factory=list)

    def lines(self) -> list[str]:
        out = [f"schedules set inactive: {self.schedules_deactivated}"]
        for title, items in (
            ("ACCESS KEYS (SH-FR-177)", self.keys),
            ("API TOKENS (SH-FR-179)", self.tokens),
            ("INTEGRATIONS (SH-FR-179)", self.integrations),
            ("PI-SPECIFIC MATCHES (SH-FR-178)", self.matches),
        ):
            out.append(f"{title}: {len(items)}")
            out.extend(f"  {item}" for item in items)
        return out


def _sidecars(db: Path) -> list[Path]:
    return [p for s in SIDECAR_SUFFIXES if (p := Path(str(db) + s)).exists()]


def remove_stale_shm(db: Path) -> None:
    """Delete an orphaned ``-shm`` once the database is closed and has no ``-wal``.

    A shared-memory index without a WAL is dead scratch data. macOS' system SQLite
    leaves it behind even after the last connection closed; SH-FR-204 forbids it.
    """
    shm, wal = Path(str(db) + "-shm"), Path(str(db) + "-wal")
    if shm.exists() and not wal.exists():
        shm.unlink()


def assert_no_sidecars(db: Path) -> None:
    leftovers = _sidecars(db)
    if leftovers:
        raise PrepareError(
            "sidecar files remain beside the copy: " + ", ".join(p.name for p in leftovers)
        )


def _quote(identifier: str) -> str:
    return '"' + identifier.replace('"', '""') + '"'


def _checkpoint(conn: sqlite3.Connection) -> None:
    busy, _log, _ckpt = conn.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
    if busy:
        raise PrepareError("wal_checkpoint(TRUNCATE) was blocked (database in use?)")


def _tables(conn: sqlite3.Connection) -> list[str]:
    rows = conn.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
    return [r[0] for r in rows if not r[0].startswith("sqlite_")]


def _columns(conn: sqlite3.Connection, table: str) -> list[tuple[str, str]]:
    return [
        (r[1], (r[2] or "").upper()) for r in conn.execute(f"PRAGMA table_info({_quote(table)})")
    ]


def _listing(conn: sqlite3.Connection, table: str, columns: tuple[str, ...]) -> list[str]:
    """One line per row with the given NON-SECRET columns (never ``user__token.id``)."""
    present = {c for c, _ in _columns(conn, table)}
    wanted = [c for c in columns if c in present]
    if not wanted:
        return []
    cols = ", ".join(_quote(c) for c in wanted)
    rows = conn.execute(f"SELECT {cols} FROM {_quote(table)} ORDER BY rowid")  # noqa: S608
    return [" ".join(f"{c}={v!r}" for c, v in zip(wanted, r)) for r in rows]


def _scan_matches(conn: sqlite3.Connection) -> list[str]:
    found: list[str] = []
    for table in _tables(conn):
        cols = _columns(conn, table)
        names = {c for c, _ in cols}
        label = "name" if "name" in names else None
        for column, ctype in cols:
            # Only text-like columns; BLOBs and numbers cannot hold the hostnames.
            if any(t in ctype for t in ("INT", "REAL", "BLOB", "NUM", "BOOL", "DATE", "FLOAT")):
                continue
            select = f"rowid, {_quote(label)}" if label else "rowid, NULL"
            rows = conn.execute(
                f"SELECT {select}, {_quote(column)} FROM {_quote(table)} "  # noqa: S608
                f"WHERE typeof({_quote(column)})='text'"
            )
            hits = [(rid, nm) for rid, nm, val in rows if PI_PATTERN.search(val)]
            if not hits:
                continue
            if label:
                found.extend(f"{table}.{column} rowid={rid} name={nm!r}" for rid, nm in hits)
            else:
                found.append(f"{table}.{column} rows={len(hits)} (table has no name column)")
    return found


def _connect_rw(db: Path) -> sqlite3.Connection:
    """Open an EXISTING database; ``?``/``#``/``%`` in the path are percent-encoded.

    ``mode=rw`` never creates a file, so a mangled URI cannot leave a stray database.
    """
    return sqlite3.connect(f"file:{quote(str(db.resolve()))}?mode=rw", uri=True)


def _precheck_on_scratch_copy(db: Path) -> None:
    """Checkpoint + integrity_check a throwaway copy of (db, -wal, -journal).

    A corrupt copy must stay byte-identical, but checkpointing writes WAL frames into the
    main file; so the first look happens on a scratch copy and the real files are only
    touched once it passed.
    """
    with tempfile.TemporaryDirectory(prefix="db-prepare-") as tmp:
        scratch = Path(tmp) / "scratch.sqlite"
        shutil.copyfile(db, scratch)
        for suffix in ("-wal", "-journal"):
            side = Path(str(db) + suffix)
            if side.is_file():
                shutil.copyfile(side, Path(str(scratch) + suffix))
        conn = _connect_rw(scratch)
        try:
            _checkpoint(conn)
            result = conn.execute("PRAGMA integrity_check").fetchall()
        finally:
            conn.close()
    if result != [("ok",)]:
        raise PrepareError(f"integrity_check failed ({len(result)} problem rows)")


def prepare(db_path: str | Path) -> Report:
    db = Path(db_path)
    if not db.is_file():
        raise PrepareError(f"{db}: not a file")
    report = Report()
    try:
        _precheck_on_scratch_copy(db)
        conn = _connect_rw(db)
        try:
            _checkpoint(conn)
            result = conn.execute("PRAGMA integrity_check").fetchall()
            if result != [("ok",)]:
                raise PrepareError(f"integrity_check failed ({len(result)} problem rows)")
            report.schedules_deactivated = conn.execute(
                "UPDATE project__schedule SET active = 0 WHERE active <> 0"
            ).rowcount
            conn.commit()
            left = conn.execute("SELECT count(*) FROM project__schedule WHERE active <> 0")
            if left.fetchone()[0]:
                raise PrepareError("schedules still active after update")
            _checkpoint(conn)
            # Some SQLite builds (macOS system Python) leave an empty -wal/-shm behind on
            # close; leaving WAL mode makes SQLite delete them (SH-FR-204).
            mode = conn.execute("PRAGMA journal_mode=DELETE").fetchone()[0]
            if mode.lower() != "delete":
                raise PrepareError(f"could not leave WAL mode (journal_mode is {mode!r})")
            report.keys = _listing(conn, "access_key", ("id", "name", "type", "project_id"))
            report.tokens = _listing(conn, "user__token", ("name", "created", "user_id"))
            report.integrations = _listing(
                conn, "project__integration", ("id", "name", "project_id")
            )
            report.matches = _scan_matches(conn)
        finally:
            conn.close()
    except sqlite3.DatabaseError as err:
        raise PrepareError(f"{db}: not a usable SQLite database: {err}") from err
    remove_stale_shm(db)
    assert_no_sidecars(db)
    return report
