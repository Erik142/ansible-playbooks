"""db-prepare.sh on synthetic databases and on a real database copied from the container."""

from __future__ import annotations

import hashlib
import shutil
import sqlite3
import subprocess
from pathlib import Path

import db_prepare
import pytest
from conftest import CONTAINER_NAMES, SeedClient, run_tool
from db_prepare import PrepareError, assert_no_sidecars, remove_stale_shm

SCHEMA = """
CREATE TABLE project (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE project__schedule (
    id INTEGER PRIMARY KEY, project_id INTEGER, name TEXT NOT NULL DEFAULT '',
    cron_format TEXT, active INTEGER NOT NULL DEFAULT 1);
CREATE TABLE access_key (id INTEGER PRIMARY KEY, name TEXT, type TEXT, project_id INTEGER,
    secret TEXT);
CREATE TABLE user__token (id TEXT PRIMARY KEY, created DATETIME, user_id INTEGER,
    name TEXT NOT NULL DEFAULT '');
CREATE TABLE project__integration (id INTEGER PRIMARY KEY, name TEXT, project_id INTEGER);
CREATE TABLE project__repository (id INTEGER PRIMARY KEY, name TEXT, git_url TEXT);
CREATE TABLE project__environment (id INTEGER PRIMARY KEY, name TEXT, json TEXT, env TEXT);
CREATE TABLE task__output (id INTEGER PRIMARY KEY, task_id INTEGER, output TEXT);
"""
SECRET_TOKEN = "TOKENSECRETVALUE0123456789abcdefghijklmnop"
SECRET_KEY_MATERIAL = "KEYSECRETMATERIAL-pi.de.int.wahlberger.dev-zzz"


def make_db(path: Path, *, wal: bool = False) -> sqlite3.Connection:
    conn = sqlite3.connect(path)
    if wal:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA wal_autocheckpoint=0")
    conn.executescript(SCHEMA)
    conn.executemany(
        "INSERT INTO project__schedule (project_id, name, cron_format, active) VALUES (?,?,?,?)",
        [(1, "nightly", "0 3 * * *", 1), (1, "weekly", "0 4 * * 0", 1), (2, "off", "* * * * *", 0)],
    )
    conn.execute("INSERT INTO project (name) VALUES ('main')")
    conn.executemany(
        "INSERT INTO access_key (name, type, project_id, secret) VALUES (?,?,?,?)",
        [("deploy-key", "ssh", 1, SECRET_KEY_MATERIAL), ("None", "none", 1, None)],
    )
    conn.execute(
        "INSERT INTO user__token (id, created, user_id, name) VALUES (?, '2026-01-01', 1, 'ci')",
        (SECRET_TOKEN,),
    )
    conn.execute("INSERT INTO project__integration (name, project_id) VALUES ('github-hook', 1)")
    conn.executemany(
        "INSERT INTO project__repository (name, git_url) VALUES (?,?)",
        [
            ("repo-pi", "ssh://git@PI.DE.INT.WAHLBERGER.DEV/x.git"),
            ("repo-ok", "https://example.invalid/x.git"),
        ],
    )
    conn.execute(
        "INSERT INTO project__environment (name, json, env) VALUES (?, ?, '{}')",
        ("env-data", '{"p":"/mnt/data/x"}'),
    )
    conn.executemany(
        "INSERT INTO task__output (task_id, output) VALUES (?,?)",
        [(1, "cd /srv"), (1, "ls pi-de-int-wahlberger-dev/roles"), (2, "x /mnt/data y")],
    )
    conn.commit()
    return conn


def schedules(path: Path) -> list[tuple[str, int]]:
    with sqlite3.connect(path) as conn:
        return conn.execute("SELECT name, active FROM project__schedule ORDER BY id").fetchall()


# -------------------------------------------------------------------- ok case
def test_ok_copy_gets_all_schedules_inactive_and_nothing_else_changed(tmp_path):
    db = tmp_path / "database.sqlite"
    make_db(db).close()

    proc = run_tool("db-prepare.sh", str(db))

    assert proc.returncode == 0, proc.stderr
    assert schedules(db) == [("nightly", 0), ("weekly", 0), ("off", 0)]
    assert "schedules set inactive: 2" in proc.stdout
    assert proc.stdout.rstrip().endswith("db-prepare: OK")
    with sqlite3.connect(db) as conn:
        assert conn.execute("SELECT count(*) FROM access_key").fetchone() == (2,)
    assert sorted(p.name for p in tmp_path.iterdir()) == ["database.sqlite"]


def test_listing_names_keys_tokens_integrations_and_matches(tmp_path):
    db = tmp_path / "database.sqlite"
    make_db(db).close()

    out = run_tool("db-prepare.sh", str(db)).stdout

    assert "ACCESS KEYS (SH-FR-177): 2" in out
    assert "name='deploy-key' type='ssh'" in out
    assert "API TOKENS (SH-FR-179): 1" in out
    assert "name='ci'" in out
    assert "INTEGRATIONS (SH-FR-179): 1" in out
    assert "name='github-hook'" in out
    # case-insensitive host match, path match, and the third pattern, each reported by row name
    assert "project__repository.git_url rowid=1 name='repo-pi'" in out
    assert "project__environment.json rowid=1 name='env-data'" in out
    # the secret column holding the Pi host name is reported by key name only
    assert "access_key.secret rowid=1 name='deploy-key'" in out
    # tables without a name column are aggregated as a count
    assert "task__output.output rows=2" in out
    assert "repo-ok" not in out  # a non-matching row is not listed as a match


def test_output_never_contains_secret_values(tmp_path):
    db = tmp_path / "database.sqlite"
    make_db(db).close()

    proc = run_tool("db-prepare.sh", str(db))

    combined = proc.stdout + proc.stderr
    assert SECRET_TOKEN not in combined
    assert "TOKENSECRET" not in combined
    assert "KEYSECRETMATERIAL" not in combined
    assert "ssh://git@" not in combined  # the URL value itself is not echoed
    assert "/mnt/data/x" not in combined


def test_clean_database_reports_no_matches(tmp_path):
    db = tmp_path / "database.sqlite"
    conn = sqlite3.connect(db)
    conn.executescript(SCHEMA)
    conn.commit()
    conn.close()

    proc = run_tool("db-prepare.sh", str(db))

    assert proc.returncode == 0
    assert "PI-SPECIFIC MATCHES (SH-FR-178): 0" in proc.stdout
    assert "schedules set inactive: 0" in proc.stdout


# ------------------------------------------------------------------ WAL case
def test_wal_beside_the_copy_is_checkpointed_into_the_database(tmp_path):
    src = tmp_path / "src"
    src.mkdir()
    live = make_db(src / "database.sqlite", wal=True)
    live.execute("INSERT INTO project (name) VALUES ('only-in-wal')")
    live.commit()
    assert (src / "database.sqlite-wal").stat().st_size > 0  # the new row is not in the main file
    copy_dir = tmp_path / "copy"
    copy_dir.mkdir()
    shutil.copy(src / "database.sqlite", copy_dir / "database.sqlite")
    shutil.copy(src / "database.sqlite-wal", copy_dir / "database.sqlite-wal")
    live.close()
    db = copy_dir / "database.sqlite"

    proc = run_tool("db-prepare.sh", str(db))

    assert proc.returncode == 0, proc.stderr
    assert sorted(p.name for p in copy_dir.iterdir()) == ["database.sqlite"]
    with sqlite3.connect(db) as conn:
        assert ("only-in-wal",) in conn.execute("SELECT name FROM project").fetchall()
    assert schedules(db) == [("nightly", 0), ("weekly", 0), ("off", 0)]


def test_stale_shm_beside_a_plain_database_is_removed(tmp_path):
    db = tmp_path / "database.sqlite"
    make_db(db).close()
    (tmp_path / "database.sqlite-shm").write_bytes(b"\0" * 32768)

    proc = run_tool("db-prepare.sh", str(db))

    assert proc.returncode == 0, proc.stderr
    assert sorted(p.name for p in tmp_path.iterdir()) == ["database.sqlite"]


@pytest.mark.parametrize("suffix", ["-wal", "-shm", "-journal"])
def test_assert_no_sidecars_names_every_remaining_file(tmp_path, suffix):
    db = tmp_path / "database.sqlite"
    db.write_bytes(b"")
    Path(str(db) + suffix).write_bytes(b"x")

    with pytest.raises(PrepareError, match=rf"remain beside the copy: database\.sqlite{suffix}$"):
        assert_no_sidecars(db)


def test_assert_no_sidecars_accepts_a_lone_database(tmp_path):
    db = tmp_path / "database.sqlite"
    db.write_bytes(b"")

    assert_no_sidecars(db)  # does not raise


def test_remove_stale_shm_keeps_a_shm_that_belongs_to_a_wal(tmp_path):
    db = tmp_path / "database.sqlite"
    (tmp_path / "database.sqlite-wal").write_bytes(b"x")
    (tmp_path / "database.sqlite-shm").write_bytes(b"x")

    remove_stale_shm(db)

    assert (tmp_path / "database.sqlite-shm").exists()
    with pytest.raises(PrepareError, match=r"database\.sqlite-shm"):
        assert_no_sidecars(db)


# ----------------------------------------------------------- failure behaviour
def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def trash_interior_pages(db: Path) -> None:
    """Corrupt interior b-tree pages but keep header and schema readable."""
    data = bytearray(db.read_bytes())
    for offset in range(8192, len(data) - 4096, 4096):
        data[offset : offset + 64] = b"\xff" * 64
    db.write_bytes(bytes(data))


def test_corrupt_database_with_a_wal_is_left_byte_identical(tmp_path):
    src = tmp_path / "src"
    src.mkdir()
    live = make_db(src / "database.sqlite", wal=True)
    live.execute("CREATE INDEX ix ON task__output(output)")
    live.executemany(
        "INSERT INTO task__output (task_id, output) VALUES (1, ?)",
        [("x" * 200 + str(i),) for i in range(500)],
    )
    live.commit()
    live.execute("PRAGMA wal_checkpoint(TRUNCATE)")  # bulk data in the main file ...
    live.execute("INSERT INTO project (name) VALUES ('only-in-wal')")  # ... one row in the WAL
    live.commit()
    copy_dir = tmp_path / "copy"
    copy_dir.mkdir()
    db, wal = copy_dir / "database.sqlite", copy_dir / "database.sqlite-wal"
    shutil.copy(src / "database.sqlite", db)
    shutil.copy(src / "database.sqlite-wal", wal)
    live.close()
    assert wal.stat().st_size > 0
    trash_interior_pages(db)
    db_before, wal_before = sha(db), sha(wal)

    proc = run_tool("db-prepare.sh", str(db))

    assert proc.returncode == 1
    assert "FAILED" in proc.stderr
    assert "OK" not in proc.stdout
    assert sha(db) == db_before
    assert sha(wal) == wal_before
    assert sorted(p.name for p in copy_dir.iterdir()) == ["database.sqlite", "database.sqlite-wal"]


@pytest.mark.parametrize("name", ["what?now.sqlite", "frag#ment.sqlite", "100%25 done?x#y.sqlite"])
def test_path_with_uri_special_characters_is_prepared_and_creates_no_stray_file(tmp_path, name):
    db = tmp_path / name
    make_db(db).close()

    proc = run_tool("db-prepare.sh", str(db))

    assert proc.returncode == 0, proc.stderr
    assert schedules(db) == [("nightly", 0), ("weekly", 0), ("off", 0)]
    assert [p.name for p in tmp_path.iterdir()] == [name]  # no 'what' / 'frag' file next to it


def test_path_with_special_characters_that_is_not_a_database_creates_no_stray_file(tmp_path):
    db = tmp_path / "bad?name#.sqlite"
    db.write_bytes(b"this is not a database" * 100)

    proc = run_tool("db-prepare.sh", str(db))

    assert proc.returncode == 1
    assert [p.name for p in tmp_path.iterdir()] == [db.name]


def test_corrupt_database_exits_nonzero_and_leaves_the_file_unmodified(tmp_path):
    db = tmp_path / "database.sqlite"
    conn = make_db(db)
    conn.execute("CREATE INDEX ix ON task__output(output)")
    conn.executemany(
        "INSERT INTO task__output (task_id, output) VALUES (1, ?)",
        [("x" * 200 + str(i),) for i in range(500)],
    )
    conn.commit()
    conn.close()
    data = bytearray(db.read_bytes())
    for offset in range(8192, len(data) - 4096, 4096):  # trash interior pages, keep header + schema
        data[offset : offset + 64] = b"\xff" * 64
    db.write_bytes(bytes(data))
    before = db.read_bytes()

    proc = run_tool("db-prepare.sh", str(db))

    assert proc.returncode == 1
    assert "FAILED" in proc.stderr
    assert "OK" not in proc.stdout
    assert db.read_bytes() == before


def test_integrity_check_failure_without_a_sqlite_error_exits_1_and_changes_nothing(tmp_path):
    db = tmp_path / "database.sqlite"
    conn = make_db(db)
    conn.execute("CREATE TABLE guarded (a INTEGER CHECK (a > 0))")
    conn.execute("PRAGMA ignore_check_constraints=ON")
    conn.execute("INSERT INTO guarded VALUES (-1)")  # readable, but integrity_check flags it
    conn.commit()
    conn.close()
    before = db.read_bytes()

    proc = run_tool("db-prepare.sh", str(db))

    assert proc.returncode == 1
    assert "integrity_check failed" in proc.stderr
    assert db.read_bytes() == before
    assert schedules(db)[0] == ("nightly", 1)


def test_prepare_fails_when_a_sidecar_appears_at_the_last_moment(tmp_path, monkeypatch):
    db = tmp_path / "database.sqlite"
    make_db(db).close()
    monkeypatch.setattr(
        db_prepare,
        "remove_stale_shm",
        lambda path: Path(str(path) + "-journal").write_bytes(b"x"),
    )

    with pytest.raises(PrepareError, match=r"remain beside the copy: database\.sqlite-journal"):
        db_prepare.prepare(db)


def test_non_sqlite_file_exits_1(tmp_path):
    db = tmp_path / "database.sqlite"
    db.write_bytes(b"this is not a database" * 100)

    proc = run_tool("db-prepare.sh", str(db))

    assert proc.returncode == 1
    assert "not a usable SQLite database" in proc.stderr


def test_missing_file_exits_1_and_creates_nothing(tmp_path):
    db = tmp_path / "nope.sqlite"

    proc = run_tool("db-prepare.sh", str(db))

    assert proc.returncode == 1
    assert "not a file" in proc.stderr
    assert not db.exists()


def test_usage_error_exits_2():
    assert run_tool("db-prepare.sh").returncode == 2
    assert run_tool("db-prepare.sh", "a", "b").returncode == 2


# ------------------------------------------ real Semaphore database (container)
def test_real_semaphore_database_with_wal_copy(semaphore_container, tool_env, tmp_path):
    seed = SeedClient(semaphore_container)
    ids = seed.seed_project("dbprep-pi-de-int-wahlberger-dev", schedule_active=True)
    seed.call("POST", "/api/user/tokens")
    seed.call(
        "POST",
        f"/api/project/{ids['project']}/integrations",
        {
            "name": "hook-x",
            "project_id": ids["project"],
            "template_id": ids["template"],
            "auth_method": "none",
        },
    )
    name = CONTAINER_NAMES[semaphore_container]
    copy_dir = tmp_path / "copy"
    copy_dir.mkdir()
    for suffix in ("", "-wal"):
        subprocess.run(
            ["docker", "cp", f"{name}:/var/lib/semaphore/database.sqlite{suffix}", str(copy_dir)],
            check=True,
            capture_output=True,
            timeout=60,
        )
    db = copy_dir / "database.sqlite"
    assert (copy_dir / "database.sqlite-wal").exists()

    proc = run_tool("db-prepare.sh", str(db))

    assert proc.returncode == 0, proc.stderr
    assert sorted(p.name for p in copy_dir.iterdir()) == ["database.sqlite"]
    with sqlite3.connect(db) as conn:
        assert conn.execute(
            "SELECT count(*) FROM project__schedule WHERE active <> 0"
        ).fetchone() == (0,)
        assert conn.execute("SELECT count(*) FROM project__schedule").fetchone()[0] >= 1
        assert conn.execute(
            "SELECT count(*) FROM project WHERE name LIKE 'dbprep-%'"
        ).fetchone() == (1,)
    assert "name='hook-x'" in proc.stdout
    assert (
        "name='dbprep-pi-de-int-wahlberger-dev'" in proc.stdout
    )  # project.name matched the host pattern
    assert "ACCESS KEYS (SH-FR-177):" in proc.stdout
    token_ids = [r[0] for r in sqlite3.connect(db).execute("SELECT id FROM user__token")]
    assert token_ids, "the seeded API token must be in the copy"
    assert all(t not in proc.stdout for t in token_ids)
