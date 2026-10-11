"""populate-vault.sh against SCRATCH playbook dirs, throwaway passwords and a fake `op`.

Nothing here touches a real vault or the real 1Password: the repo root, the VM playbook dir
and every source playbook dir are built in a tmp dir; `op` is a script in a tmp bin dir that
answers only the scratch reference; no ANSIBLE_* variable reaches the tool, so each scratch
playbook's own ansible.cfg applies exactly as it would for a real source playbook.
The tool dir under test is $POPULATE_TOOLS_DIR (mutation runs) or the real tools/.
"""

from __future__ import annotations

import os
import re
import stat
import subprocess
from pathlib import Path

import pytest
from conftest import BASE_PATH, TOOLS, find_ansible_vault
from test_vault_hash import make_vault
from vault_hash import parse_top_level

TOOLS_UNDER_TEST = Path(os.environ.get("POPULATE_TOOLS_DIR", str(TOOLS)))
OPS_DIR_REAL = Path(__file__).resolve().parents[2]
VAULT_REL = Path("inventories/production/group_vars/all/vault.yml")
ANSIBLE_VAULT = find_ansible_vault()
pytestmark = pytest.mark.skipif(
    ANSIBLE_VAULT is None, reason="no working ansible-vault (set ANSIBLE_VAULT_BIN)"
)

OP_REF = "op://ScratchVault/Scratch Item/password"
VM_PW = "vm-throwaway-password-ZZZ"
PI_PW = "pi-throwaway-password-YYY"
COPIED = {
    "vault_semaphore_access_key_encryption": "SRC-access-key-enc-111",
    "vault_semaphore_cookie_hash": "SRC-cookie-hash-222",
    "vault_semaphore_cookie_encryption": "SRC-cookie-enc-333",
    "vault_semaphore_admin_password": "SRC-admin-pw-444",
    "vault_semaphore_oidc_client_secret": "SRC-oidc-secret-555",
    "vault_cloudflare_dns_api_token": "SRC-cf-token-666",
    "vault_notify_failure_resend_api_key": "SRC-resend-key-777",
}
GENERATED = ("vault_restic_backup_repo_password", "vault_restic_backup_rest_server_password")
ALL_VALUES = [*COPIED.values(), VM_PW, PI_PW]
SOURCE_SCRIPT = """#!/bin/sh
cat "$(dirname "$0")/pw"
"""


def _executable(path: Path, text: str) -> None:
    path.write_text(text)
    path.chmod(0o755)


def _playbook(root: Path, name: str, content: str, password: str) -> Path:
    """A scratch source playbook: ansible.cfg + .vault_pass.sh (cat pw) + encrypted vault."""
    pb = root / name
    pb.mkdir(parents=True)
    make_vault(pb, content, password)
    (pb / "ansible.cfg").write_text("[defaults]\nvault_password_file = .vault_pass.sh\n")
    _executable(pb / ".vault_pass.sh", SOURCE_SCRIPT)
    return pb


def _pi_content(overrides: dict[str, str | None] | None = None) -> str:
    values = {**COPIED, "vault_unrelated_extra": "SRC-unrelated-888", **(overrides or {})}
    return "---\n" + "".join(f'{k}: "{v}"\n' for k, v in values.items() if v is not None)


class Scratch:
    def __init__(self, tmp: Path, pi_overrides: dict[str, str | None] | None = None) -> None:
        self.tmp = tmp
        self.repo = tmp / "repo"
        self.repo.mkdir()
        self.pi = _playbook(self.repo, "pi-de-int-wahlberger-dev", _pi_content(pi_overrides), PI_PW)
        self.ops = self.repo / "ops-de-wahlberger-dev"
        self.ops.mkdir()
        self.bin = tmp / "bin"
        self.bin.mkdir()
        self.op_log = tmp / "op.log"
        _executable(
            self.bin / "op",
            f"""#!/bin/sh
echo "$*" >> "{self.op_log}"
[ "$1" = read ] && [ "$2" = "{OP_REF}" ] && [ "$3" = --no-newline ] || exit 1
printf %s "$FAKE_OP_PASSWORD"
""",
        )
        # The scratch VM dir's own config calls the fake op too: if the tool ever ran
        # ansible-vault from this dir, op.log would show a second call (hermeticity canary).
        (self.ops / "ansible.cfg").write_text("[defaults]\nvault_password_file = .vault_pass.sh\n")
        _executable(
            self.ops / ".vault_pass.sh",
            f'#!/bin/sh\nexec op read "{OP_REF}" --no-newline\n',
        )
        self.target = self.ops / VAULT_REL

    def env(self, **extra: str) -> dict[str, str]:
        return {
            "PATH": f"{self.bin}:{BASE_PATH}:{ANSIBLE_VAULT.parent}",
            "HOME": str(Path.home()),
            "FAKE_OP_PASSWORD": VM_PW,
            **extra,
        }

    def run(self, *args: str, env: dict[str, str] | None = None, tools: Path = TOOLS_UNDER_TEST):
        return subprocess.run(
            [
                str(tools / "populate-vault.sh"),
                "--ops-dir",
                str(self.ops),
                "--repo-root",
                str(self.repo),
                *args,
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=300,
            env=env or self.env(),
            cwd=self.tmp,
        )

    def vm_view(self) -> dict[str, str]:
        cfg = self.tmp / "empty.cfg"
        cfg.write_text("")
        pw = self.tmp / "vmpw"
        pw.write_text(VM_PW)
        proc = subprocess.run(
            [str(ANSIBLE_VAULT), "view", str(self.target), "--vault-password-file", str(pw)],
            capture_output=True,
            text=True,
            check=True,
            timeout=120,
            env={"PATH": BASE_PATH, "ANSIBLE_CONFIG": str(cfg)},
            cwd=self.tmp,
        )
        return parse_top_level(proc.stdout)

    def op_calls(self) -> list[str]:
        return self.op_log.read_text().splitlines() if self.op_log.exists() else []


@pytest.fixture
def scratch(tmp_path: Path) -> Scratch:
    s = Scratch(tmp_path)
    tmp_path.chmod(0o700)
    return s


def assert_no_values(*outputs: str, extra: tuple[str, ...] = ()) -> None:
    for text in outputs:
        for secret in (*ALL_VALUES, *extra):
            assert secret not in text, "a secret value reached the output"


# ------------------------------------------------------------------ happy path
def test_builds_vault_with_copied_and_generated_keys_and_prints_no_value(scratch):
    proc = scratch.run()

    assert proc.returncode == 0, proc.stderr
    data = scratch.vm_view()
    assert set(data) == set(COPIED) | set(GENERATED)
    for key, value in COPIED.items():
        assert data[key] == value
    for key in GENERATED:
        assert re.fullmatch(r"[A-Za-z0-9]{32}", data[key])
    assert data[GENERATED[0]] != data[GENERATED[1]]
    assert_no_values(proc.stdout, proc.stderr, extra=tuple(data[k] for k in GENERATED))
    assert "vault_unrelated_extra" not in data
    for key in COPIED:
        assert f"{key}: copied from pi:{key}" in proc.stdout
        assert f"{key}: match" in proc.stdout
    for key in GENERATED:
        assert f"{key}: generated (alnum32)" in proc.stdout
        assert f"{key}: ok (alnum32)" in proc.stdout
    assert "all verified" in proc.stdout
    assert "sha256:" not in proc.stdout


def test_vault_file_is_encrypted_mode_0600_and_leaves_no_temp_files(scratch):
    assert scratch.run().returncode == 0

    assert scratch.target.read_bytes().startswith(b"$ANSIBLE_VAULT;")
    assert stat.S_IMODE(scratch.target.stat().st_mode) == 0o600
    assert sorted(p.name for p in scratch.target.parent.iterdir()) == ["vault.yml"]
    assert b"SRC-" not in scratch.target.read_bytes()


def test_password_comes_from_the_exact_reference_in_vault_pass_sh_and_op_runs_once(scratch):
    assert scratch.run().returncode == 0

    # exactly one op call, with the scratch .vault_pass.sh reference: so neither a hard-coded
    # reference nor ansible-vault run from the VM dir (its ansible.cfg would call op again).
    assert scratch.op_calls() == [f"read {OP_REF} --no-newline"]


def test_show_hash_prints_sha256_first_8_hex_but_still_no_value(scratch):
    import hashlib

    proc = scratch.run("--show-hash")

    assert proc.returncode == 0, proc.stderr
    key = "vault_semaphore_admin_password"
    digest = hashlib.sha256(COPIED[key].encode()).hexdigest()[:8]
    assert f"{key}: copied from pi:{key}  sha256:{digest}" in proc.stdout
    assert len(re.findall(r"sha256:[0-9a-f]{8}\b", proc.stdout)) == 9
    assert_no_values(proc.stdout, proc.stderr, extra=tuple(scratch.vm_view()[k] for k in GENERATED))


def test_real_manifest_example_and_vars_agree_on_the_key_set():
    from populate_vault import parse_manifest

    manifest = {e.key for e in parse_manifest((TOOLS / "vault-manifest.yml").read_text())}
    group_vars = OPS_DIR_REAL / "inventories/production/group_vars/all"
    example = set(
        re.findall(r"^(vault_[a-z0-9_]+):", (group_vars / "vault.yml.example").read_text(), re.M)
    )
    referenced = set(re.findall(r"\bvault_[a-z0-9_]+", (group_vars / "vars.yml").read_text()))
    assert manifest == example == referenced
    assert len(manifest) == 9


def test_real_vault_pass_sh_holds_exactly_one_op_reference_for_the_vm_item():
    from populate_vault import op_reference

    assert (
        op_reference(OPS_DIR_REAL) == "op://DevOps/Ansible Vault - ops-de-wahlberger-dev/password"
    )


# ------------------------------------------------------------ overwrite rules
def test_refuses_to_overwrite_a_real_vault_without_force_and_leaves_it_unchanged(scratch):
    assert scratch.run().returncode == 0
    before = scratch.target.read_bytes()

    proc = scratch.run()

    assert proc.returncode == 3
    assert "REFUSED" in proc.stderr and "--force" in proc.stderr
    assert scratch.target.read_bytes() == before
    assert_no_values(proc.stdout, proc.stderr)


def test_refuses_even_with_replace_placeholder_when_the_vault_is_real(scratch):
    assert scratch.run().returncode == 0
    before = scratch.target.read_bytes()

    proc = scratch.run("--replace-placeholder")

    assert proc.returncode == 3
    assert scratch.target.read_bytes() == before


def test_force_rebuilds_but_keeps_the_generated_passwords_unless_regenerate(scratch):
    assert scratch.run().returncode == 0
    first = scratch.vm_view()

    kept = scratch.run("--force")
    assert kept.returncode == 0, kept.stderr
    assert f"{GENERATED[0]}: kept (alnum32)" in kept.stdout
    assert {k: scratch.vm_view()[k] for k in GENERATED} == {k: first[k] for k in GENERATED}

    fresh = scratch.run("--force", "--regenerate-secrets")
    assert fresh.returncode == 0, fresh.stderr
    assert f"{GENERATED[0]}: generated (alnum32)" in fresh.stdout
    assert scratch.vm_view()[GENERATED[0]] != first[GENERATED[0]]


def test_placeholder_vault_needs_replace_placeholder_and_is_then_replaced(scratch):
    # the shipped placeholder is encrypted with a throwaway password, not the VM password
    placeholder, _ = make_vault(scratch.tmp / "ph", "---\nvault_x: fake\n", "someone-elses-pw")
    scratch.target.parent.mkdir(parents=True)
    scratch.target.write_bytes(placeholder.read_bytes())
    before = scratch.target.read_bytes()

    refused = scratch.run()
    assert refused.returncode == 3
    assert "--replace-placeholder" in refused.stderr
    assert scratch.target.read_bytes() == before

    done = scratch.run("--replace-placeholder")
    assert done.returncode == 0, done.stderr
    assert set(scratch.vm_view()) == set(COPIED) | set(GENERATED)


def test_plaintext_file_at_the_target_is_refused_without_force(scratch):
    scratch.target.parent.mkdir(parents=True)
    scratch.target.write_text("plain: text\n")

    proc = scratch.run("--replace-placeholder")

    assert proc.returncode == 3
    assert scratch.target.read_text() == "plain: text\n"


# --------------------------------------------------------------- source checks
def test_missing_source_key_refuses_before_writing_and_names_the_key(tmp_path):
    s = Scratch(tmp_path, {"vault_cloudflare_dns_api_token": None})

    proc = s.run()

    assert proc.returncode == 2
    assert "vault_cloudflare_dns_api_token" in proc.stderr and "missing" in proc.stderr
    assert not s.target.exists()
    assert_no_values(proc.stdout, proc.stderr)


def test_empty_source_value_refuses_before_writing(tmp_path):
    s = Scratch(tmp_path, {"vault_semaphore_cookie_hash": ""})

    proc = s.run()

    assert proc.returncode == 2
    assert "vault_semaphore_cookie_hash" in proc.stderr and "empty" in proc.stderr
    assert not s.target.exists()


def test_every_missing_key_is_listed_in_one_run(tmp_path):
    s = Scratch(
        tmp_path,
        {"vault_cloudflare_dns_api_token": None, "vault_notify_failure_resend_api_key": None},
    )

    proc = s.run()

    assert proc.returncode == 2
    assert "vault_cloudflare_dns_api_token" in proc.stderr
    assert "vault_notify_failure_resend_api_key" in proc.stderr


def test_missing_source_vault_file_is_an_error(scratch):
    (scratch.pi / VAULT_REL).unlink()

    proc = scratch.run()

    assert proc.returncode == 2
    assert "source vault missing" in proc.stderr
    assert not scratch.target.exists()


def test_op_failure_writes_nothing(scratch):
    proc = scratch.run(env=scratch.env(FAKE_OP_PASSWORD=""))

    assert proc.returncode == 2
    assert "op" in proc.stderr
    assert not scratch.target.exists()


def test_a_source_changing_between_copy_and_verify_is_reported_as_mismatch(scratch):
    # The source's password script swaps in a different vault on its 2nd call (the re-read).
    key = "vault_semaphore_admin_password"
    alt, _ = make_vault(scratch.tmp / "alt", _pi_content({key: "SRC-CHANGED-999"}), PI_PW)
    (scratch.pi / "vault.alt").write_bytes(alt.read_bytes())
    _executable(
        scratch.pi / ".vault_pass.sh",
        """#!/bin/sh
d=$(dirname "$0")
n=$(cat "$d/count" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$d/count"
if [ "$n" -ge 2 ]; then cp "$d/vault.alt" "$d/inventories/production/group_vars/all/vault.yml"; fi
cat "$d/pw"
""",
    )

    proc = scratch.run()

    assert proc.returncode == 1
    assert f"{key}: MISMATCH" in proc.stdout
    assert proc.stdout.count(": match") == 6
    assert "MISMATCH: 1 check(s) failed" in proc.stdout
    assert_no_values(proc.stdout, proc.stderr, extra=("SRC-CHANGED-999",))


# ------------------------------------------------------------- manifest rules
@pytest.mark.parametrize(
    ("text", "needle"),
    [
        ("vault_a: pi:vault_a\nvault_a: pi:vault_b\n", "duplicate"),
        ("plain_a: pi:vault_a\n", "not a vault_* key"),
        ("vault_a: laptop:vault_a\n", "source must be"),
        ("vault_a: generate:alnum8\n", "unknown generator"),
        ("vault_a: pi:Bad Key\n", "bad source key"),
        ("# nothing\n", "no entries"),
    ],
)
def test_bad_manifests_are_rejected_before_anything_runs(scratch, text, needle):
    manifest = scratch.tmp / "m.yml"
    manifest.write_text(text)

    proc = scratch.run("--manifest", str(manifest))

    assert proc.returncode == 2
    assert needle in proc.stderr
    assert scratch.op_calls() == []


def test_manifest_can_name_other_playbooks_and_the_value_is_copied_from_there(tmp_path):
    s = Scratch(tmp_path)
    _playbook(
        s.repo, "cloud-wahlberger-dev", '---\nvault_cloud_only: "CLOUD-val-123"\n', "cloud-pw"
    )
    manifest = tmp_path / "m.yml"
    manifest.write_text("vault_from_cloud: cloud:vault_cloud_only\nvault_gen: generate:alnum32\n")

    proc = s.run("--manifest", str(manifest))

    assert proc.returncode == 0, proc.stderr
    assert s.vm_view()["vault_from_cloud"] == "CLOUD-val-123"
    assert "vault_from_cloud: match" in proc.stdout
    assert "CLOUD-val-123" not in proc.stdout + proc.stderr
