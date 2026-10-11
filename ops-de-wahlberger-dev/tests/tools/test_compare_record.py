"""compare-record.py: record vs VM, counts, newest migrated task id (PA-2), inactive schedules."""

from __future__ import annotations

import json
import time

import pytest
from conftest import SeedClient, run_tool
from semaphore_record import RecordError, compare_records, load_record

CREDS = {"SEMAPHORE_USER": "u", "SEMAPHORE_PASSWORD": "p"}


def make_record(**overrides) -> dict:
    record = {
        "schema": 1,
        "semaphore_version": "v2.19.16",
        "counts": {"keys": 3, "projects": 1, "schedules": 2, "users": 1},
        "newest_task_id": 42,
        "active_schedules": [],
    }
    record.update(overrides)
    return record


# ------------------------------------------------------------------ pure logic
def test_identical_records_have_no_differences():
    assert compare_records(make_record(), make_record()) == []


def test_count_difference_names_the_kind_and_both_values():
    current = make_record(counts={"keys": 2, "projects": 1, "schedules": 2, "users": 1})

    diffs = compare_records(make_record(), current)

    assert [str(d) for d in diffs] == ["DIFF counts.keys: record=3 vm=2"]


def test_a_kind_missing_on_one_side_is_a_difference():
    current = make_record(counts={"keys": 3, "projects": 1, "users": 1})

    diffs = compare_records(make_record(), current)

    assert [str(d) for d in diffs] == ["DIFF counts.schedules: record=2 vm=None"]


def test_newest_task_id_difference_is_reported():
    diffs = compare_records(make_record(), make_record(newest_task_id=43))

    assert [str(d) for d in diffs] == ["DIFF newest_task_id: record=42 vm=43"]


def test_null_task_ids_on_both_sides_are_equal():
    assert compare_records(make_record(newest_task_id=None), make_record(newest_task_id=None)) == []


def test_active_vm_schedule_is_a_difference_even_when_counts_match():
    active = [{"project_id": 1, "id": 5, "name": "nightly", "template": "t", "cron": "* * * * *"}]

    diffs = compare_records(make_record(), make_record(active_schedules=active))

    assert len(diffs) == 1
    assert "active_schedule project=1 id=5 name='nightly'" in str(diffs[0])


def test_load_record_rejects_garbage(tmp_path):
    bad = tmp_path / "r.json"
    bad.write_text('{"hello": 1}')
    with pytest.raises(RecordError, match="not a step-4 record"):
        load_record(str(bad))
    bad.write_text("not json")
    with pytest.raises(RecordError, match="cannot read record"):
        load_record(str(bad))
    with pytest.raises(RecordError, match="cannot read record"):
        load_record(str(tmp_path / "missing.json"))


# ------------------------------------------------------------------------- CLI
def routes(keys: int = 3, newest: int = 42, active: bool = False) -> dict:
    return {
        "/api/projects": [{"id": 1}],
        "/api/users": [{"id": 1}],
        "/api/info": {"version": "v2.19.16"},
        "/api/project/1/keys": [{"id": i} for i in range(keys)],
        "/api/project/1/repositories": [],
        "/api/project/1/inventory": [],
        "/api/project/1/environment": [],
        "/api/project/1/templates": [],
        "/api/project/1/schedules": [{"id": 1, "name": "s", "active": active}],
        "/api/project/1/tasks": [{"id": newest}],
    }


def write_record(tmp_path, fake_semaphore, **route_kw) -> str:
    src = fake_semaphore(routes(**route_kw))
    out = run_tool("step4-record.py", src.base_url, env=CREDS)
    assert out.returncode == 0, out.stderr
    path = tmp_path / "record.json"
    path.write_text(out.stdout)
    return str(path)


def test_cli_exits_0_when_everything_matches(tmp_path, fake_semaphore):
    record = write_record(tmp_path, fake_semaphore)
    vm = fake_semaphore(routes())

    proc = run_tool("compare-record.py", record, vm.base_url, env=CREDS)

    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert proc.stdout.startswith("OK")


def test_cli_exits_1_and_names_the_differing_count(tmp_path, fake_semaphore):
    record = write_record(tmp_path, fake_semaphore)
    vm = fake_semaphore(routes(keys=4))

    proc = run_tool("compare-record.py", record, vm.base_url, env=CREDS)

    assert proc.returncode == 1
    assert proc.stdout.splitlines() == ["DIFF counts.keys: record=3 vm=4"]


def test_cli_exits_1_when_the_newest_task_id_differs(tmp_path, fake_semaphore):
    record = write_record(tmp_path, fake_semaphore)
    vm = fake_semaphore(routes(newest=43))

    proc = run_tool("compare-record.py", record, vm.base_url, env=CREDS)

    assert proc.returncode == 1
    assert proc.stdout.splitlines() == ["DIFF newest_task_id: record=42 vm=43"]


def test_cli_exits_1_when_a_vm_schedule_is_active(tmp_path, fake_semaphore):
    record = write_record(tmp_path, fake_semaphore)
    vm = fake_semaphore(routes(active=True))

    proc = run_tool("compare-record.py", record, vm.base_url, env=CREDS)

    assert proc.returncode == 1
    assert "active_schedule" in proc.stdout


def test_cli_bad_record_exits_2_without_contacting_the_server(tmp_path, fake_semaphore):
    vm = fake_semaphore(routes())
    bad = tmp_path / "bad.json"
    bad.write_text("[]")

    proc = run_tool("compare-record.py", str(bad), vm.base_url, env=CREDS)

    assert proc.returncode == 2
    assert "not a step-4 record" in proc.stderr
    assert vm.requests == []


def test_cli_usage_error_exits_2():
    assert run_tool("compare-record.py", "only-one-arg").returncode == 2


# ------------------------------------------------ against the real v2.19.16 image
def test_container_state_matches_its_own_record_until_something_changes(
    semaphore_container, tool_env, tmp_path
):
    seed = SeedClient(semaphore_container)
    seed.seed_project("cmp-test", schedule_active=False)
    rec = run_tool("step4-record.py", semaphore_container, env=tool_env)
    record_path = tmp_path / "record.json"
    record_path.write_text(rec.stdout)
    assert json.loads(rec.stdout)["active_schedules"] == []

    same = run_tool("compare-record.py", str(record_path), semaphore_container, env=tool_env)
    assert same.returncode == 0, same.stdout + same.stderr

    # a new project object changes the project count AND the auto-created "None" key count
    seed.call("POST", "/api/projects", {"name": "extra"})
    changed = run_tool("compare-record.py", str(record_path), semaphore_container, env=tool_env)
    assert changed.returncode == 1
    counts = json.loads(rec.stdout)["counts"]
    assert changed.stdout.splitlines() == [
        f"DIFF counts.keys: record={counts['keys']} vm={counts['keys'] + 1}",
        f"DIFF counts.projects: record={counts['projects']} vm={counts['projects'] + 1}",
    ]


def wait_for_task_row(seed: SeedClient, project: int, task_id: int, timeout: float = 90) -> None:
    """Block until the queued task is listed by /tasks (the tool reads the newest id there)."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        rows = seed.call("GET", f"/api/project/{project}/tasks") or []
        if any(row["id"] == task_id for row in rows):
            return
        time.sleep(0.5)
    raise AssertionError(
        f"task {task_id} has no row in /api/project/{project}/tasks after {timeout}s"
    )


def test_container_new_task_row_is_detected_as_newest_id_difference(
    semaphore_container, tool_env, tmp_path
):
    seed = SeedClient(semaphore_container)
    ids = seed.seed_project("cmp-task", schedule_active=False)
    first_id = seed.run_task(ids["project"], ids["template"])
    wait_for_task_row(seed, ids["project"], first_id)
    rec = run_tool("step4-record.py", semaphore_container, env=tool_env)
    record_path = tmp_path / "record.json"
    record_path.write_text(rec.stdout)
    recorded_id = json.loads(rec.stdout)["newest_task_id"]

    new_id = seed.run_task(ids["project"], ids["template"])  # what an AC-22 --check run would do
    wait_for_task_row(seed, ids["project"], new_id)

    proc = run_tool("compare-record.py", str(record_path), semaphore_container, env=tool_env)
    assert proc.returncode == 1
    assert proc.stdout.splitlines() == [f"DIFF newest_task_id: record={recorded_id} vm={new_id}"]


def test_container_active_schedule_fails_the_comparison(semaphore_container, tool_env, tmp_path):
    seed = SeedClient(semaphore_container)
    ids = seed.seed_project("cmp-sched", schedule_active=False)
    rec = run_tool("step4-record.py", semaphore_container, env=tool_env)
    record_path = tmp_path / "record.json"
    record_path.write_text(rec.stdout)
    active_id = seed.add_schedule(ids["project"], ids["template"], active=True)
    try:
        proc = run_tool("compare-record.py", str(record_path), semaphore_container, env=tool_env)
    finally:
        seed.call("DELETE", f"/api/project/{ids['project']}/schedules/{active_id}")

    # counts also differ (one more schedule) and the active one is named
    assert proc.returncode == 1
    assert "DIFF counts.schedules" in proc.stdout
    assert f"active_schedule project={ids['project']} id={active_id}" in proc.stdout
