"""Tests for roles/restic_server/files/restic-maintenance.py (T-15)."""

from __future__ import annotations

import io
import json
import re

import pytest
from conftest import SCRIPT

GOOD_A = "a" * 64
GOOD_B = "b" * 64
FORGED = "f" * 64

SNAPSHOTS = ["restic", "snapshots", "--json"]
DRY_RUN = ["forget", "--dry-run", "--json", "--keep-daily", "7", "--keep-weekly", "4",
           "--keep-monthly", "6", "--retry-lock", "30m"]  # fmt: skip
PRUNE = ["prune", "--retry-lock", "30m"]
CHECK = ["check", "--read-data-subset=10%", "--retry-lock", "30m"]


def run(mod, env, *extra):
    out, err = io.StringIO(), io.StringIO()
    argv = ["--repo-root", str(env.root), "--repo", "cloud", "--restic", str(env.restic), *extra]
    code = mod.main(argv, env=env.environ, out=out, err=err)
    return code, out.getvalue(), err.getvalue()


def sub_argvs(env):
    return env.argvs()


def forget_ids(*ids):
    return ["forget", *ids, "--retry-lock", "30m"]


def test_within_skew_runs_verified_sequence_in_order_and_exits_zero(script_module, env):
    env.set_snapshots([env.add_snapshot(GOOD_A, 0, 60), env.add_snapshot(GOOD_B, 3600, 0)])
    env.set_dry_run_removals([GOOD_B])

    code, out, _ = run(script_module, env)

    assert code == 0
    assert sub_argvs(env) == [SNAPSHOTS[1:], DRY_RUN, SNAPSHOTS[1:], forget_ids(GOOD_B), PRUNE, CHECK]
    assert "offending" not in out


def test_nothing_to_remove_skips_forget_but_still_prunes_and_checks(script_module, env):
    env.set_snapshots([env.add_snapshot(GOOD_A, 0)])

    code, _, _ = run(script_module, env)

    assert code == 0
    assert sub_argvs(env) == [SNAPSHOTS[1:], DRY_RUN, SNAPSHOTS[1:], PRUNE, CHECK]


def test_forget_gets_explicit_ids_never_keep_flags_or_prune(script_module, env):
    env.set_snapshots([env.add_snapshot(GOOD_A, 0), env.add_snapshot(GOOD_B, 0)])
    env.set_dry_run_removals([GOOD_B, GOOD_A, GOOD_A])

    run(script_module, env)

    real = [a for a in sub_argvs(env) if a[0] == "forget" and "--dry-run" not in a]
    assert real == [forget_ids(GOOD_A, GOOD_B)]


def test_snapshot_appearing_after_guard_aborts_with_exit_3_and_deletes_nothing(script_module, env):
    genuine = env.add_snapshot(GOOD_A, 0)
    env.set_snapshots([genuine])
    env.set_dry_run_removals([GOOD_A])
    env.environ["FAKE_RESTIC_SNAPSHOTS_2"] = json.dumps([genuine, env.add_snapshot(FORGED, 86400)])

    code, out, _ = run(script_module, env)

    assert code == 3
    assert "snapshot list differs" in out
    assert sub_argvs(env) == [SNAPSHOTS[1:], DRY_RUN, SNAPSHOTS[1:]]


def test_removal_of_snapshot_unknown_to_guard_aborts_with_exit_3_and_deletes_nothing(script_module, env):
    env.set_snapshots([env.add_snapshot(GOOD_A, 0)])
    env.set_dry_run_removals([GOOD_A, FORGED])

    code, out, _ = run(script_module, env)

    assert code == 3
    assert FORGED in out and "unverified" in out
    assert not any(a[0] in ("prune", "check") or (a[0] == "forget" and "--dry-run" not in a) for a in sub_argvs(env))


def test_snapshot_removed_after_guard_also_aborts(script_module, env):
    a, b = env.add_snapshot(GOOD_A, 0), env.add_snapshot(GOOD_B, 0)
    env.set_snapshots([a, b])
    env.environ["FAKE_RESTIC_SNAPSHOTS_2"] = json.dumps([a])

    code, out, err = run(script_module, env)

    assert code == 3
    assert sub_argvs(env) == [SNAPSHOTS[1:], DRY_RUN, SNAPSHOTS[1:]]
    assert "snapshot list differs from the guarded list" in out
    assert "unverified" not in out
    assert "snapshot set changed between check and forget" in err


def test_snapshot_time_changed_after_guard_with_same_id_aborts_with_exit_3(script_module, env):
    genuine = env.add_snapshot(GOOD_A, 0)
    env.set_snapshots([genuine])
    env.environ["FAKE_RESTIC_SNAPSHOTS_2"] = json.dumps([{**genuine, "time": "2099-01-01T00:00:00Z"}])

    code, out, _ = run(script_module, env)

    assert code == 3
    assert "snapshot list differs" in out
    assert sub_argvs(env) == [SNAPSHOTS[1:], DRY_RUN, SNAPSHOTS[1:]]


def test_each_restic_step_is_announced_before_it_runs(script_module, env):
    env.set_snapshots([env.add_snapshot(GOOD_A, 0)])
    env.set_dry_run_removals([GOOD_A])

    code, out, _ = run(script_module, env)

    assert code == 0
    announced = [line for line in out.splitlines() if line.startswith("running ")]
    assert announced == [
        "running snapshots", "running forget --dry-run", "running snapshots",
        "running forget", "running prune", "running check",
    ]  # fmt: skip


def test_remove_null_in_dry_run_group_means_nothing_to_forget(script_module, env):
    env.set_snapshots([env.add_snapshot(GOOD_A, 0)])
    env.environ["FAKE_RESTIC_DRYRUN"] = '[{"keep": [], "remove": null}]'

    code, _, _ = run(script_module, env)

    assert code == 0
    assert sub_argvs(env) == [SNAPSHOTS[1:], DRY_RUN, SNAPSHOTS[1:], PRUNE, CHECK]


@pytest.mark.parametrize("payload", ["{not json", '{"remove": []}', '[{"remove": [{"id": "../x"}]}]', "[1]"])
def test_bad_dry_run_output_fails_with_exit_1_and_deletes_nothing(script_module, env, payload):
    env.set_snapshots([env.add_snapshot(GOOD_A, 0)])
    env.environ["FAKE_RESTIC_DRYRUN"] = payload

    code, _, err = run(script_module, env)

    assert code == 1 and "dry-run" in err
    assert len(sub_argvs(env)) == 2


def test_restic_gets_repository_via_env_not_argv(script_module, env):
    env.set_snapshots([])

    run(script_module, env)

    assert {c["env"]["RESTIC_REPOSITORY"] for c in env.calls()} == {str(env.repo)}
    assert all(str(env.repo) not in " ".join(a) for a in sub_argvs(env))


def test_custom_retention_and_subset_are_passed_through(script_module, env):
    env.set_snapshots([])

    code, _, _ = run(script_module, env, "--keep-daily", "3", "--keep-weekly", "2",
                     "--keep-monthly", "1", "--check-subset", "5%", "--retry-lock", "5m")  # fmt: skip

    assert code == 0
    assert sub_argvs(env)[1:] == [
        ["forget", "--dry-run", "--json", "--keep-daily", "3", "--keep-weekly", "2",
         "--keep-monthly", "1", "--retry-lock", "5m"],
        ["snapshots", "--json"],
        ["prune", "--retry-lock", "5m"],
        ["check", "--read-data-subset=5%", "--retry-lock", "5m"],
    ]  # fmt: skip


@pytest.mark.parametrize("recorded_offset", [2 * 86400, -3 * 86400])
def test_forged_time_stops_before_forget_and_lists_only_forged_id(script_module, env, recorded_offset):
    env.set_snapshots([
        env.add_snapshot(GOOD_A, 0), env.add_snapshot(GOOD_B, 10),
        env.add_snapshot(FORGED, recorded_offset),
    ])  # fmt: skip

    code, out, _ = run(script_module, env)

    assert code == 3
    assert sub_argvs(env) == [["snapshots", "--json"]]
    assert FORGED in out
    assert GOOD_A not in out and GOOD_B not in out


def test_every_offending_snapshot_is_listed(script_module, env):
    other = "c" * 64
    env.set_snapshots([env.add_snapshot(FORGED, 86400), env.add_snapshot(other, -3 * 86400),
                       env.add_snapshot(GOOD_A, 0)])  # fmt: skip

    code, out, _ = run(script_module, env)

    assert code == 3
    assert FORGED in out and other in out and GOOD_A not in out


FUTURE_LIMIT = 6 * 3600
PAST_LIMIT = 48 * 3600


def test_future_skew_exactly_at_limit_passes(script_module, env):
    env.set_snapshots([env.add_snapshot(GOOD_A, FUTURE_LIMIT)])

    code, _, _ = run(script_module, env)

    assert code == 0
    assert len(sub_argvs(env)) == 5


def test_future_skew_one_second_over_limit_fails(script_module, env):
    env.set_snapshots([env.add_snapshot(GOOD_A, FUTURE_LIMIT + 1)])

    code, out, _ = run(script_module, env)

    assert code == 3
    assert GOOD_A in out
    assert sub_argvs(env) == [["snapshots", "--json"]]


def test_past_allowance_exactly_at_limit_passes(script_module, env):
    env.set_snapshots([env.add_snapshot(GOOD_A, -PAST_LIMIT)])

    code, _, _ = run(script_module, env)

    assert code == 0
    assert len(sub_argvs(env)) == 5


def test_past_allowance_one_second_over_limit_fails(script_module, env):
    env.set_snapshots([env.add_snapshot(GOOD_A, -PAST_LIMIT - 1)])

    code, out, _ = run(script_module, env)

    assert code == 3
    assert GOOD_A in out
    assert sub_argvs(env) == [["snapshots", "--json"]]


def test_backup_longer_than_future_skew_passes(script_module, env):
    # Regression: a 10 h backup (start time 10 h before upload end) must not trip the guard.
    env.set_snapshots([env.add_snapshot(GOOD_A, -10 * 3600)])

    code, _, _ = run(script_module, env)

    assert code == 0


def test_max_skew_hours_option_changes_the_future_limit(script_module, env):
    env.set_snapshots([env.add_snapshot(GOOD_A, 2 * 3600)])

    code, _, _ = run(script_module, env, "--max-skew-hours", "1")

    assert code == 3


def test_max_past_hours_option_changes_the_past_limit(script_module, env):
    env.set_snapshots([env.add_snapshot(GOOD_A, -2 * 3600)])

    assert run(script_module, env, "--max-past-hours", "3")[0] == 0
    assert run(script_module, env, "--max-past-hours", "1")[0] == 3


def test_snapshot_without_file_counts_as_offending(script_module, env):
    entry = {"id": GOOD_A, "time": "2027-01-15T08:00:00Z"}  # no file on disk
    env.set_snapshots([entry])

    code, out, _ = run(script_module, env)

    assert code == 3 and GOOD_A in out
    assert len(sub_argvs(env)) == 1


@pytest.mark.parametrize("entry", [
    {"id": "../../etc/passwd", "time": "2027-01-15T08:00:00Z"},
    {"id": GOOD_A, "time": "not-a-time"},
    {"id": GOOD_A},
])  # fmt: skip
def test_malformed_snapshot_entry_trips_guard(script_module, env, entry):
    (env.repo / "snapshots" / GOOD_A).write_text("x")
    env.set_snapshots([entry])

    code, _, _ = run(script_module, env)

    assert code == 3
    assert len(sub_argvs(env)) == 1


def test_missing_repository_fails_without_calls_or_directories(script_module, env, tmp_path):
    (env.repo / "config").unlink()
    before = sorted(p.relative_to(tmp_path) for p in tmp_path.rglob("*"))

    code, _, err = run(script_module, env)

    assert code == 2
    assert "repository missing" in err
    assert env.argvs() == []
    assert sorted(p.relative_to(tmp_path) for p in tmp_path.rglob("*")) == before


def test_missing_repository_directory_is_not_created(script_module, env):
    code = script_module.main(
        ["--repo-root", str(env.root), "--repo", "other", "--restic", str(env.restic)],
        env=env.environ,
        out=io.StringIO(),
        err=io.StringIO(),
    )

    assert code == 2
    assert not (env.root / "other").exists()
    assert env.argvs() == []


@pytest.mark.parametrize("name", ["../cloud", "a/b", "", ".hidden", "x y"])
def test_invalid_repository_name_is_rejected(script_module, env, name):
    code = script_module.main(
        ["--repo-root", str(env.root), "--repo", name, "--restic", str(env.restic)],
        env=env.environ,
        out=io.StringIO(),
        err=io.StringIO(),
    )

    assert code == 2
    assert env.argvs() == []


@pytest.mark.parametrize("name", ["../repos/cloud", "a/b", "./cloud"])
def test_traversal_name_resolving_to_a_valid_repository_is_still_rejected(script_module, env, name):
    (env.root / "a" / "b").mkdir(parents=True)
    (env.root / "a" / "b" / "config").write_text("cfg")
    assert (env.root / name / "config").is_file()  # arrange: the path really is a valid repo

    err = io.StringIO()
    code = script_module.main(
        ["--repo-root", str(env.root), "--repo", name, "--restic", str(env.restic)],
        env=env.environ,
        out=io.StringIO(),
        err=err,
    )

    assert code == 2
    assert "invalid repository name" in err.getvalue()
    assert env.argvs() == []


@pytest.mark.parametrize("password", [None, ""])
def test_missing_or_empty_password_fails_before_any_restic_call(script_module, env, password):
    if password is None:
        del env.environ["RESTIC_PASSWORD"]
    else:
        env.environ["RESTIC_PASSWORD"] = password

    code, _, err = run(script_module, env)

    assert code == 2 and "RESTIC_PASSWORD" in err
    assert env.argvs() == []


@pytest.mark.parametrize(
    ("failing", "expected_calls"),
    [("SNAPSHOTS", 1), ("DRYRUN", 2), ("FORGET", 4), ("PRUNE", 5), ("CHECK", 6)],
)
def test_failing_step_exits_nonzero_and_skips_later_steps(script_module, env, failing, expected_calls):
    env.set_snapshots([env.add_snapshot(GOOD_A, 0)])
    env.set_dry_run_removals([GOOD_A])
    env.environ[f"FAKE_RESTIC_FAIL_{failing}"] = "1"

    code, _, err = run(script_module, env)

    assert code == 1
    assert len(sub_argvs(env)) == expected_calls
    assert failing.lower() in err.replace("-", "")


def test_prune_failure_is_reported_with_exit_code_and_skips_check(script_module, env):
    env.set_snapshots([])
    env.environ["FAKE_RESTIC_FAIL_PRUNE"] = "3"

    code, _, err = run(script_module, env)

    assert code == 1 and "prune exited 3" in err
    assert not any(a[0] == "check" for a in sub_argvs(env))


def test_invalid_json_from_restic_fails_without_forget(script_module, env):
    env.environ["FAKE_RESTIC_SNAPSHOTS"] = "{not json"

    code, _, _ = run(script_module, env)

    assert code == 1
    assert len(sub_argvs(env)) == 1


def test_non_list_snapshots_json_fails_with_exit_1(script_module, env):
    env.environ["FAKE_RESTIC_SNAPSHOTS"] = '{"id": "x"}'

    code, _, err = run(script_module, env)

    assert code == 1 and "not a list" in err
    assert len(sub_argvs(env)) == 1


def test_missing_restic_binary_exits_nonzero(script_module, env):
    env.environ["FAKE_RESTIC_SNAPSHOTS"] = "[]"
    code = script_module.main(
        ["--repo-root", str(env.root), "--repo", "cloud", "--restic", str(env.root / "nope")],
        env=env.environ,
        out=io.StringIO(),
        err=io.StringIO(),
    )

    assert code == 1


def test_password_never_appears_in_argv(script_module, env):
    env.set_snapshots([env.add_snapshot(GOOD_A, 0)])

    run(script_module, env)

    assert all(env.environ["RESTIC_PASSWORD"] not in " ".join(a) for a in sub_argvs(env))
    assert {c["env"]["RESTIC_PASSWORD"] for c in env.calls()} == {env.environ["RESTIC_PASSWORD"]}


def test_nanosecond_and_offset_times_parse_to_the_same_instant(script_module):
    a = script_module.parse_restic_time("2027-01-15T08:00:00.123456789Z")
    b = script_module.parse_restic_time("2027-01-15T10:00:00.123456+02:00")

    assert a == pytest.approx(b)


def test_naive_timestamp_is_treated_as_utc(script_module):
    naive = script_module.parse_restic_time("2027-01-15T08:00:00")
    aware = script_module.parse_restic_time("2027-01-15T08:00:00Z")

    assert naive == aware


def test_find_skewed_reports_malformed_id_even_when_a_file_of_that_name_exists(script_module, tmp_path):
    short = "a" * 63
    (tmp_path / short).write_text("x")

    result = script_module.find_skewed_snapshots([{"id": short, "time": "2027-01-15T08:00:00Z"}], tmp_path, 1e9, 1e9)

    assert result == [short]


def test_full_run_never_invokes_restic_init(script_module, env):
    env.set_snapshots([env.add_snapshot(GOOD_A, 0)])
    env.set_dry_run_removals([GOOD_A])

    code, _, _ = run(script_module, env)

    assert code == 0
    assert {a[0] for a in sub_argvs(env)} == {"snapshots", "forget", "prune", "check"}


def test_script_source_has_no_destructive_pattern():
    src = SCRIPT.read_text()
    pattern = (
        r"community\.general\.(parted|filesystem|btrfs_subvolume)|mkfs|wipefs|sgdisk|sfdisk|"
        r"\bparted\b|\bdd\b|blkdiscard|shred|cryptsetup|btrfs (device (add|delete|remove)|replace)|"
        r"subvolume (create|delete)|chattr"
    )  # BD-AC-04 (a)
    assert re.search(pattern, src) is None


def test_retention_policy_and_removal_set_are_logged_before_forget(script_module, env):
    env.set_snapshots([env.add_snapshot(GOOD_A, 0)])
    env.set_dry_run_removals([GOOD_A])

    code, out, _ = run(script_module, env)

    assert code == 0
    assert "retention policy: keep 7 daily, 4 weekly, 6 monthly snapshots; forgetting 1 verified snapshot(s): " in out
    assert out.index("retention policy:") < out.index("running forget\n")
