"""Fixtures for the negative tests of static-checks.sh, pr-boundaries.sh and
guard-tests.sh (PLAN.md T-14).

Each test works on a throwaway git repository built from a trimmed copy of the
real tree (only the files the checks read) plus synthetic stand-ins for what the
later tasks deliver (README.md, CLAUDE.md, renovate rules, flow-rule record).
The baseline passes; a test seeds one defect and expects exactly that check to
FAIL. Hermetic: empty ANSIBLE_CONFIG, a canary `op` on PATH that records any
call, throwaway vault password, .vault_pass.sh never run. Stdlib only.
"""
import json
import os
import re
import shutil
import stat
import subprocess
import textwrap
from pathlib import Path

import pytest

OPS_REAL = Path(__file__).resolve().parents[2]
REAL = OPS_REAL.parent
V = "ops-de-wahlberger-dev"
N = "nas-de-int-wahlberger-dev"
C = "cloud-wahlberger-dev"
PI = "pi-de-int-wahlberger-dev"

VARS = "inventories/production/group_vars/all/vars.yml"
EXAMPLE = "inventories/production/group_vars/all/vault.yml.example"

COPY_OPS = [
    "site.yml", ".vault_pass.sh", ".yamllint", ".ansible-lint",
    "inventories/production/hosts.yml", VARS, EXAMPLE,
    "roles/security/handlers/main.yml", "roles/security/tasks/sshd.yml",
    "roles/security/templates/zypper-dup-request-reboot.sh.j2",
    "roles/security/templates/zypper-dup.service.j2",
    "roles/restic_backup/defaults/main.yml", "roles/restic_backup/templates",
    "roles/firewall/tasks", "roles/firewall/defaults",
    "roles/ssh_authorized_keys/meta/argument_specs.yml", "roles/ssh_authorized_keys/defaults/main.yml",
    "roles/ssh_authorized_keys/tasks", "roles/ssh_authorized_keys/vars",
    "molecule/default/verify-ssh-keys.yml", "molecule/default/verify-security.yml",
    "tests/static-checks.sh", "tests/pr-boundaries.sh", "tests/guard-tests.sh",
]
COPY_OTHER = [
    "inventories/production/group_vars/all/vars.yml",
    "roles/ssh_authorized_keys/meta/argument_specs.yml", "roles/ssh_authorized_keys/defaults/main.yml",
    "roles/ssh_authorized_keys/tasks", "roles/ssh_authorized_keys/vars",
]

README_STEPS = "\n".join(
    "## Step {n}\n\nGate: SH-AC-{n:02d}.\n\nRollback: undo step {n}.\n".format(n=n) for n in range(10)
)
README = textwrap.dedent("""\
    # ops-de-wahlberger-dev

    {steps}
    ## PR table

    | PR | Content |
    |---|---|
    | A | x |
    | A2 | x |
    | A3 | x |
    | B | x |
    | B2 | x |
    | C | x |
    | C2 | x |
    | C-R | x |
    | D | x |
    | E | x |

    ## Excluded roles

    `ansible-playbook site.yml -e semaphore_image=... -e ansible_host=ops.de.int.wahlberger.dev`
    (see the semaphore_image note)

    ## Database restore

    restic restore ...

    ## Cloud Firewall

    hcloud firewall describe ...

    ## Break-glass

    Use the Hetzner console.
    """).replace("{steps}", README_STEPS)

RENOVATE = {
    "packageRules": [
        {"matchFileNames": ["pi-de-int-wahlberger-dev/**"], "enabled": False},
        {"matchFileNames": ["ops-de-wahlberger-dev/roles/semaphore/defaults/main.yml"], "enabled": False},
    ]
}


def git(cwd, *args):
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t",
               GIT_COMMITTER_EMAIL="t@t", GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null")
    return subprocess.run(["git", *args], cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout


def _copy(src_root, dst_root, rel):
    src = src_root / rel
    dst = dst_root / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    if src.is_dir():
        shutil.copytree(src, dst, ignore=shutil.ignore_patterns("__pycache__", ".ansible", ".pytest_cache"))
    else:
        shutil.copy2(src, dst)


@pytest.fixture(scope="session")
def template_repo(tmp_path_factory):
    """A committed baseline repository, built once."""
    root = tmp_path_factory.mktemp("tmpl")
    for rel in COPY_OPS:
        _copy(OPS_REAL, root / V, rel)
    for d in (N, C):
        for rel in COPY_OTHER:
            _copy(REAL / d, root / d, rel)
    # The baseline is "stage A": the three ZeroTier values empty, whatever the real
    # tree ships today (pull request A2 sets them). The tests below edit these lines.
    ops_vars = root / V / "inventories/production/group_vars/all/vars.yml"
    text = ops_vars.read_text()
    for key in ("vm_zt_ip", "vm_zt_iface", "cloud_zt_ip"):
        text, n = re.subn(rf'^{key}: ".*"$', f'{key}: ""', text, flags=re.M)
        assert n == 1, f"fixture drift: {key} not found once in the ops vars.yml"
    ops_vars.write_text(text)
    # Stage A also has no new automation key yet (pull request C adds it); the
    # tests below add it themselves.
    for d in (N, C, V):
        p = root / d / "inventories/production/group_vars/all/vars.yml"
        p.write_text(re.sub(r"  - 'from=.*?semaphore-automation@ops\.de\.wahlberger\.dev'\n", "", p.read_text(), flags=re.S))
    (root / V / "README.md").write_text(README)
    (root / V / "CLAUDE.md").write_text("# conventions\n")
    (root / V / "docs").mkdir()
    (root / V / "docs/zerotier-flow-rules.md").write_text("# Flow rules\n\n## Before (2026-10-10)\n\nrules\n")
    (root / "renovate.json").write_text(json.dumps(RENOVATE, indent=2))
    # Plaintext-looking placeholder; tests that need a real vault replace it.
    gv = root / V / "inventories/production/group_vars/all"
    (gv / "vault.yml").write_text("$ANSIBLE_VAULT;1.1;AES256\n00\n")
    # Deterministic guards for the guard-tests wrapper tests.
    gd = root / V / "tests/guards.d"
    gd.mkdir()
    (gd / "ok.yml").write_text(OK_GUARD)
    (gd / "bad.yml").write_text(BAD_GUARD)
    git(root, "init", "-q", "-b", "master")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "baseline")
    return root


OK_GUARD = """---
- name: ok
  hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - ansible.builtin.assert: {that: [true]}
"""
BAD_GUARD = """---
- name: bad
  hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - ansible.builtin.fail: {msg: seeded guard failure}
"""


class Repo:
    def __init__(self, root, tmp, canary_dir):
        self.root = root
        self.ops = root / V
        self.tmp = tmp
        self.canary_dir = canary_dir

    def path(self, rel):
        return self.root / rel

    def edit(self, rel, old, new, count=1):
        p = self.path(rel)
        text = p.read_text()
        assert old in text, "fixture drift: %r not in %s" % (old, rel)
        p.write_text(text.replace(old, new, count))

    def write(self, rel, text):
        p = self.path(rel)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    def env(self, **extra):
        env = {k: v for k, v in os.environ.items() if not k.startswith(("STATIC_CHECKS_", "PR_BOUNDARIES_", "STEP7_"))}
        cfg = self.tmp / "empty-ansible.cfg"
        cfg.write_text("")
        env.update(
            ANSIBLE_CONFIG=str(cfg), PATH="%s:%s" % (self.canary_dir, env["PATH"]),
            STATIC_CHECKS_SKIP_LINT="1", STATIC_CHECKS_SKIP_RENDER="1", STATIC_CHECKS_SKIP_UNIT="1",
            TMPDIR=str(self.tmp), HOME=str(self.tmp), GIT_CONFIG_GLOBAL="/dev/null",
        )
        env.pop("ANSIBLE_VAULT_PASSWORD_FILE", None)
        if "YAMLLINT" not in env and os.path.exists("/opt/homebrew/bin/yamllint"):
            env["YAMLLINT"] = "/opt/homebrew/bin/yamllint"   # the ~/Library/Python one has a stale interpreter
        env.update(extra)
        return env

    def run(self, script, *args, **env):
        p = subprocess.run(["bash", str(self.ops / "tests" / script), *args], cwd=self.root, env=self.env(**env),
                           capture_output=True, text=True, timeout=300)
        return p.returncode, p.stdout + p.stderr

    def static(self, ids, **env):
        return self.run("static-checks.sh", STATIC_CHECKS_ONLY=ids, **env)

    def commit_all(self, msg="change"):
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "-m", msg)

    def op_called(self):
        return (self.canary_dir / "op-was-called").exists()


@pytest.fixture
def repo(template_repo, tmp_path):
    root = tmp_path / "repo"
    # git may write lock files (maintenance.lock, gc.pid) into the template while
    # this copy runs; a vanished lock makes copytree fail. Copy without them.
    shutil.copytree(template_repo, root, symlinks=True,
                    ignore=shutil.ignore_patterns("*.lock", "gc.pid", "gc.log"))
    canary = tmp_path / "canary-bin"
    canary.mkdir()
    op = canary / "op"
    op.write_text('#!/bin/sh\ntouch "%s/op-was-called"\nexit 1\n' % canary)
    op.chmod(op.stat().st_mode | stat.S_IXUSR)
    r = Repo(root, tmp_path, canary)
    yield r
    assert not r.op_called(), "a test reached the 1Password CLI (.vault_pass.sh ran)"


def line_for(out, ident):
    for l in out.splitlines():
        if re.match(r"(PASS|FAIL|SKIPPED)\s+%s\b" % re.escape(ident), l):
            return l
    return None


def status(out, ident):
    l = line_for(out, ident)
    return l.split()[0] if l else None
