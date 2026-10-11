"""Tests for tests/guard-tests.sh: one guard per invocation (PA-6), strict names."""
import pytest

from conftest import git


def test_list_names_the_guards(repo):
    rc, out = repo.run("guard-tests.sh", "--list")
    assert rc == 0 and "ok" in out.split() and "bad" in out.split(), out


def test_passing_guard_exits_zero(repo):
    rc, out = repo.run("guard-tests.sh", "ok")
    assert rc == 0, out


def test_failing_guard_exits_nonzero_and_names_it(repo):
    rc, out = repo.run("guard-tests.sh", "bad")
    assert rc == 1 and "seeded guard failure" in out, out


def test_guards_are_separate_invocations(repo):
    # Running one guard must not run another: `bad` fails, `ok` still passes alone.
    assert repo.run("guard-tests.sh", "ok")[0] == 0
    assert repo.run("guard-tests.sh", "bad")[0] != 0
    assert repo.run("guard-tests.sh", "ok")[0] == 0


@pytest.mark.parametrize("arg", ["../ok", "ok.yml", "nope", ".hidden", "a/b", "ok;id"])
def test_bad_names_are_usage_errors(repo, arg):
    rc, out = repo.run("guard-tests.sh", arg)
    assert rc == 2, out


def test_no_args_and_two_args_are_usage_errors(repo):
    assert repo.run("guard-tests.sh")[0] == 2
    assert repo.run("guard-tests.sh", "ok", "bad")[0] == 2
