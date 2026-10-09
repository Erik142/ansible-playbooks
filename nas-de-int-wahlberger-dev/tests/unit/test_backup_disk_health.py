"""Tests for roles/backup_disk/templates/backup-disk-health.py.j2 (T-10).

The template's only Jinja is the CONFIG block; it is replaced textually so the
tests need nothing but pytest. Fakes stand in for findmnt, btrfs, stat, the
clock and the directory tree (the injection seams of ``main``).
"""

from __future__ import annotations

import io
import re
import types
from pathlib import Path

import pytest

TEMPLATE = Path(__file__).resolve().parents[2] / "roles/backup_disk/templates/backup-disk-health.py.j2"
UUID = "11111111-2222-4333-8444-555555555555"
NOW = 1_800_000_000
HOUR = 3600
MOUNT = {"path": "/mnt/backup/btrbk", "subvol": "/@btrbk"}
DATA = "/mnt/backup/btrbk/data"
CLOUD = "/mnt/data/restic-repos/cloud/snapshots"


@pytest.fixture(scope="module")
def health():
    text = TEMPLATE.read_text()
    text, subs = re.subn(r"^\{%.*%\}\n", "", text, flags=re.M)
    assert subs == 1
    text, subs = re.subn(r"^CONFIG = .*$", "CONFIG = {}", text, flags=re.M)
    assert subs == 1
    assert "{{" not in text and "{%" not in text
    module = types.ModuleType("backup_disk_health")
    exec(compile(text, str(TEMPLATE), "exec"), module.__dict__)  # noqa: S102
    return module


class Fakes:
    """Fake host: mount table, btrfs exit code, directory tree with birth times."""

    def __init__(self):
        self.mounted = {MOUNT["path"]: UUID + " /@btrbk"}
        self.stats_code = 0
        self.tree: dict[str, dict[str, int | str]] = {}  # dir -> {child: birth epoch, or raw stat output}
        self.calls: list[list[str]] = []

    def run(self, argv):
        """Validate the exact argv the script must use, then answer like the real tool."""
        self.calls.append(list(argv))
        if argv[0] == "findmnt":
            assert argv[1:-1] == ["--noheadings", "--raw", "--output", "UUID,FSROOT", "--mountpoint"], argv
            line = self.mounted.get(argv[-1])
            return (0, line + "\n") if line else (1, "")
        if argv[0] == "btrfs":
            assert argv[:4] == ["btrfs", "device", "stats", "--check"] and len(argv) == 5, argv
            return self.stats_code, ""
        if argv[0] == "stat":
            assert argv[:4] == ["stat", "-c", "%W", "--"] and len(argv) == 5, argv
            directory, name = argv[-1].rsplit("/", 1)
            return 0, str(self.tree[directory][name]) + "\n"
        raise AssertionError(argv)

    def check(self, health, freshness, mounts=(MOUNT,)):
        out = io.StringIO()
        config = {"uuid": UUID, "mounts": list(mounts), "freshness": freshness}
        code = health.main(
            config, run=self.run, now=lambda: NOW,
            listdir=lambda p: list(self.tree[p]), exists=lambda p: p in self.tree, out=out,
        )  # fmt: skip
        return code, out.getvalue()


@pytest.fixture
def fakes():
    return Fakes()


def entry(path, hours=26):
    return {"path": path, "max_age_hours": hours}


def test_healthy_disk_with_fresh_entries_exits_zero(health, fakes):
    fakes.tree = {DATA: {"old": NOW - 100 * HOUR, "new": NOW - 25 * HOUR}, CLOUD: {"s": NOW - 1 * HOUR}}
    code, out = fakes.check(health, [entry(DATA), entry(CLOUD)])
    assert code == 0
    assert "backup disk healthy" in out
    assert "FAIL" not in out


def test_one_fresh_child_is_enough_even_if_siblings_are_old(health, fakes):
    fakes.tree = {DATA: {"a": NOW - 500 * HOUR, "b": NOW - 2 * HOUR}}
    assert fakes.check(health, [entry(DATA)])[0] == 0


def test_stale_entry_fails_and_names_the_path(health, fakes):
    fakes.tree = {DATA: {"a": NOW - 27 * HOUR}, CLOUD: {"s": NOW - HOUR}}
    code, out = fakes.check(health, [entry(DATA), entry(CLOUD)])
    assert code == 1
    assert f"FAIL: {DATA}: stale, newest child is 27 h old, limit 26 h" in out
    assert f"FAIL: {CLOUD}" not in out


def test_age_exactly_at_the_limit_is_stale(health, fakes):
    fakes.tree = {DATA: {"a": NOW - 26 * HOUR}}
    code, out = fakes.check(health, [entry(DATA)])
    assert code == 1 and DATA in out


def test_max_age_hours_zero_always_fails(health, fakes):
    fakes.tree = {DATA: {"a": NOW}}
    code, out = fakes.check(health, [entry(DATA, 0)])
    assert code == 1
    assert f"FAIL: {DATA}: stale" in out


def test_empty_directory_is_stale(health, fakes):
    fakes.tree = {DATA: {}}
    code, out = fakes.check(health, [entry(DATA)])
    assert code == 1
    assert f"FAIL: {DATA}: stale, no direct child with a known birth time" in out


def test_unknown_birth_time_zero_is_not_counted_as_fresh(health, fakes):
    fakes.tree = {DATA: {"a": 0}}
    assert fakes.check(health, [entry(DATA)])[0] == 1


def test_missing_freshness_path_is_logged_and_skipped(health, fakes):
    fakes.tree = {DATA: {"a": NOW - HOUR}}
    code, out = fakes.check(health, [entry(DATA), entry(CLOUD)])
    assert code == 0
    assert f"{CLOUD}: absent, skipped" in out
    assert "FAIL" not in out


def test_unmounted_path_fails_and_skips_device_stats(health, fakes):
    fakes.mounted = {}
    code, out = fakes.check(health, [])
    assert code == 1
    assert f"FAIL: {MOUNT['path']}: not mounted" in out
    assert not [c for c in fakes.calls if c[0] == "btrfs"]


@pytest.mark.parametrize("live", [
    "99999999-2222-4333-8444-555555555555 /@btrbk",  # other filesystem
    UUID + " /",  # top level instead of @btrbk
])  # fmt: skip
def test_wrong_filesystem_or_subvolume_fails(health, fakes, live):
    fakes.mounted[MOUNT["path"]] = live
    code, out = fakes.check(health, [])
    assert code == 1
    assert f"mounted as '{live}', expected '{UUID} /@btrbk'" in out


def test_nonzero_device_counter_fails(health, fakes):
    fakes.stats_code = 1
    code, out = fakes.check(health, [])
    assert code == 1
    assert "btrfs device stats --check exited 1" in out
    assert ["btrfs", "device", "stats", "--check", MOUNT["path"]] in fakes.calls


def test_run_command_keeps_the_oserror_text_for_a_missing_binary(health):
    code, out = health.run_command(["/nonexistent/binary-for-test"])
    assert code == 127
    assert "/nonexistent/binary-for-test" in out


def test_missing_btrfs_is_reported_as_not_runnable_not_as_counters(health, fakes):
    def run(argv):
        if argv[0] == "btrfs":
            return 127, "[Errno 2] No such file or directory: 'btrfs'"
        return fakes.run(argv)

    out = io.StringIO()
    config = {"uuid": UUID, "mounts": [MOUNT], "freshness": []}
    code = health.main(config, run=run, now=lambda: NOW, out=out)

    assert code == 1
    text = out.getvalue()
    assert f"FAIL: {MOUNT['path']}: btrfs could not be run: [Errno 2] No such file or directory: 'btrfs'" in text
    assert "counters non-zero" not in text


def test_missing_findmnt_is_reported_as_not_runnable_not_as_unmounted(health, fakes):
    def run(argv):
        return (127, "no findmnt") if argv[0] == "findmnt" else fakes.run(argv)

    out = io.StringIO()
    code = health.main({"uuid": UUID, "mounts": [MOUNT], "freshness": []}, run=run, now=lambda: NOW, out=out)

    assert code == 1
    assert f"FAIL: {MOUNT['path']}: findmnt could not be run: no findmnt" in out.getvalue()
    assert "not mounted" not in out.getvalue()


def test_non_numeric_stat_output_is_ignored_for_that_child(health, fakes):
    fakes.tree = {DATA: {"bad": "?", "good": NOW - HOUR}}
    assert fakes.check(health, [entry(DATA)])[0] == 0


def test_only_non_numeric_stat_output_means_no_known_birth_time(health, fakes):
    fakes.tree = {DATA: {"bad": "?"}}
    code, out = fakes.check(health, [entry(DATA)])
    assert code == 1
    assert f"FAIL: {DATA}: stale, no direct child with a known birth time" in out


def test_birth_time_one_second_after_epoch_zero_counts_as_known(health, fakes):
    fakes.tree = {DATA: {"a": 1}}
    code, out = fakes.check(health, [entry(DATA, 10**6)])
    assert code == 0
    assert f"{DATA}: fresh" in out


def test_age_one_second_below_the_limit_is_fresh(health, fakes):
    fakes.tree = {DATA: {"a": NOW - 26 * HOUR + 1}}
    assert fakes.check(health, [entry(DATA)])[0] == 0


def test_zero_birth_times_alongside_a_real_one_use_the_real_one(health, fakes):
    fakes.tree = {DATA: {"unknown": 0, "real": NOW - HOUR}}
    assert fakes.check(health, [entry(DATA)])[0] == 0


def test_wrong_uuid_and_stale_entry_are_both_reported_without_stats_for_the_bad_mount(health, fakes):
    fakes.mounted[MOUNT["path"]] = "99999999-2222-4333-8444-555555555555 /@btrbk"
    fakes.tree = {DATA: {"a": NOW - 99 * HOUR}}
    code, out = fakes.check(health, [entry(DATA)])
    assert code == 1
    assert out.count("FAIL:") == 2
    assert not [c for c in fakes.calls if c[0] == "btrfs"]


def test_second_mount_failing_does_not_hide_the_first_mounts_stats(health, fakes):
    other = {"path": "/mnt/backup/other", "subvol": "/@other"}
    fakes.stats_code = 1
    code, out = fakes.check(health, [], mounts=(MOUNT, other))
    assert code == 1
    assert f"FAIL: {MOUNT['path']}: btrfs device stats --check exited 1" in out
    assert f"FAIL: {other['path']}: not mounted" in out


def test_all_problems_are_reported_in_one_run(health, fakes):
    fakes.stats_code = 2
    fakes.tree = {DATA: {"a": NOW - 99 * HOUR}}
    code, out = fakes.check(health, [entry(DATA)])
    assert code == 1
    assert out.count("FAIL:") == 2


def test_check_only_reads(health, fakes):
    fakes.tree = {DATA: {"a": NOW - HOUR}}
    fakes.check(health, [entry(DATA)])
    assert {c[0] for c in fakes.calls} <= {"findmnt", "btrfs", "stat"}
    assert all(c[:3] == ["btrfs", "device", "stats"] for c in fakes.calls if c[0] == "btrfs")
