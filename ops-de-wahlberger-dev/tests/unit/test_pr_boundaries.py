"""Negative tests for tests/pr-boundaries.sh (SH-BR-16, SH-FR-97, SH-AC-63)."""
import pytest

from conftest import C, N, PI, V, VARS, git

OPS_VARS = V + "/" + VARS


def branch(repo, files):
    """Create a feature branch whose only change is `files` ({rel: text})."""
    git(repo.root, "checkout", "-q", "-b", "pr")
    for rel, text in files.items():
        repo.write(rel, text)
    repo.commit_all()


def pr(repo, name, **env):
    return repo.run("pr-boundaries.sh", name, **env)


A_FILES = {
    V + "/new-role/tasks/main.yml": "x",
    N + "/roles/ssh_authorized_keys/tasks/main.yml": "x",
    C + "/roles/ssh_authorized_keys/tasks/main.yml": "x",
    C + "/roles/restic_backup/defaults/main.yml": "x",
    "renovate.json": "{}",
    "semaphore-migration/PLAN.md": "x",
}


def test_a_allows_its_file_classes(repo):
    branch(repo, A_FILES)
    rc, out = pr(repo, "A")
    assert rc == 0, out


@pytest.mark.parametrize("rel", [
    PI + "/site.yml",
    N + "/inventories/production/group_vars/all/vars.yml",
    C + "/inventories/production/group_vars/all/vars.yml",
    N + "/roles/restic_server/defaults/main.yml",
    "README.md.txt",
])
def test_a_rejects_other_classes(repo, rel):
    branch(repo, dict(A_FILES, **{rel: "x"}))
    rc, out = pr(repo, "A")
    assert rc == 1 and rel in out, out


def test_a_rejects_pi_dir_even_for_a_markdown_file(repo):
    branch(repo, dict(A_FILES, **{PI + "/README.md": "x"}))
    rc, out = pr(repo, "A")
    assert rc == 1 and "frozen" in out, out


def test_a_rejects_pi_dir_when_untracked_only(repo):
    repo.write(PI + "/x", "x")
    rc, out = pr(repo, "A")
    assert rc == 1 and PI in out, out


def test_a_rejects_pi_dir_deletion(repo):
    # A deleted tracked file counts as a change too (SH-FR-97).
    repo.write(PI + "/x", "x")
    repo.commit_all("pi exists on master")
    git(repo.root, "checkout", "-q", "-b", "pr")
    (repo.path(PI + "/x")).unlink()
    repo.write(V + "/a.yml", "x")
    repo.commit_all()
    rc, out = pr(repo, "A")
    assert rc == 1 and PI + "/x" in out, out


@pytest.mark.parametrize("name", ["A2", "A3"])
def test_a2_a3_fail_on_any_file_outside_vm_dir(repo, name):
    files = {OPS_VARS: "x", V + "/docs/zerotier-flow-rules.md": "x", "renovate.json": "{}"}
    branch(repo, files)
    rc, out = pr(repo, name)
    assert rc == 1 and "renovate.json" in out, out


@pytest.mark.parametrize("name", ["A2", "A3"])
def test_a2_a3_pass_inside_vm_dir(repo, name):
    branch(repo, {OPS_VARS: "x", V + "/docs/zerotier-flow-rules.md": "x", V + "/README.md": "x"})
    rc, out = pr(repo, name)
    assert rc == 0, out


def test_a2_needs_vars_and_flow_rule_record(repo):
    branch(repo, {OPS_VARS: "x"})
    rc, out = pr(repo, "A2")
    assert rc == 1 and "zerotier-flow-rules.md" in out, out


def test_a2_rejects_nas_file(repo):
    branch(repo, {OPS_VARS: "x", V + "/docs/zerotier-flow-rules.md": "x", N + "/README.md": "x"})
    rc, out = pr(repo, "A2")
    assert rc == 1 and N + "/README.md" in out, out


def test_b_allows_nas_group_vars_only(repo):
    branch(repo, {N + "/inventories/production/group_vars/all/vault.yml": "x", N + "/inventories/production/group_vars/all/vars.yml": "x"})
    assert pr(repo, "B")[0] == 0


def test_b_rejects_restic_server_role_which_is_b2(repo):
    branch(repo, {N + "/roles/restic_server/defaults/main.yml": "x"})
    assert pr(repo, "B")[0] == 1
    assert pr(repo, "B2")[0] == 0


@pytest.mark.parametrize("name", ["C", "C2", "C-R"])
def test_c_variants_only_key_lists(repo, name):
    keys = [N + "/" + VARS, C + "/" + VARS, OPS_VARS]
    branch(repo, {k: "x" for k in keys})
    assert pr(repo, name)[0] == 0
    repo.write(V + "/roles/x/tasks/main.yml", "x")
    repo.commit_all()
    rc, out = pr(repo, name)
    assert rc == 1 and V + "/roles/x/tasks/main.yml" in out, out


def test_d_allows_homepage_flag_and_renovate(repo):
    branch(repo, {N + "/roles/homepage/defaults/main.yml": "x", OPS_VARS: "x", "renovate.json": "{}", "README.md": "x"})
    assert pr(repo, "D")[0] == 0
    repo.write(N + "/roles/security/tasks/main.yml", "x")
    repo.commit_all()
    assert pr(repo, "D")[0] == 1


def test_e_pi_dir_only_with_step7_done(repo):
    repo.write(PI + "/x", "x")
    repo.commit_all("pi on master")
    git(repo.root, "checkout", "-q", "-b", "pr")
    repo.path(PI + "/x").unlink()
    repo.write("renovate.json", "{}")
    repo.commit_all()
    rc, out = pr(repo, "E")
    assert rc == 1 and PI + "/x" in out, out
    rc, out = pr(repo, "E", STEP7_DONE="1")
    assert rc == 0, out


def test_step7_done_does_not_unlock_other_prs(repo):
    branch(repo, {PI + "/x": "x", V + "/a": "x"})
    rc, out = pr(repo, "A", STEP7_DONE="1")
    assert rc == 1 and "frozen" in out, out


def test_empty_diff_fails(repo):
    rc, out = pr(repo, "A")
    assert rc == 1 and "no changed files" in out, out


@pytest.mark.parametrize("arg", ["Z", "a", "A4", "", "../A"])
def test_unknown_pr_is_a_usage_error(repo, arg):
    assert pr(repo, arg)[0] == 2


def test_missing_argument_is_a_usage_error(repo):
    assert repo.run("pr-boundaries.sh")[0] == 2
