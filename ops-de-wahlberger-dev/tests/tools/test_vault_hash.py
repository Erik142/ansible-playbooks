"""vault-hash-compare.sh: only match/MISMATCH is printed (scratch vaults, throwaway password)."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest
from conftest import BASE_PATH, find_ansible_vault, run_tool
from vault_hash import (
    MATCH,
    MISMATCH,
    VaultError,
    _parse_flat,
    compare_values,
    parse_top_level,
    run,
)

SECRET_A = "s3cr3t-VALUE-alpha"
SECRET_B = "s3cr3t-VALUE-beta"
VAULT_REL = Path("inventories/production/group_vars/all/vault.yml")

ANSIBLE_VAULT = find_ansible_vault()
needs_ansible_vault = pytest.mark.skipif(
    ANSIBLE_VAULT is None, reason="no working ansible-vault (set ANSIBLE_VAULT_BIN)"
)


VAULT_ENV_VARS = ("ANSIBLE_VAULT_PASSWORD_FILE", "ANSIBLE_VAULT_IDENTITY_LIST")


def hermetic_env(root: Path) -> dict[str, str]:
    """Env for any ansible-vault call: empty ANSIBLE_CONFIG, no inherited vault settings.

    Without it Ansible reads ./ansible.cfg of the cwd (the repo's names .vault_pass.sh,
    which runs `op read` against the real 1Password).
    """
    cfg = root / "empty-ansible.cfg"
    cfg.parent.mkdir(parents=True, exist_ok=True)
    cfg.write_text("")
    env = {k: v for k, v in os.environ.items() if k not in VAULT_ENV_VARS}
    env["ANSIBLE_CONFIG"] = str(cfg)
    return env


def make_vault(root: Path, content: str, password: str = "throwaway-1") -> tuple[Path, Path]:
    """Encrypt ``content`` into <root>/inventories/.../vault.yml with a scratch password."""
    vault = root / VAULT_REL
    vault.parent.mkdir(parents=True)
    vault.write_text(content)
    pw = root / "pw"
    pw.write_text(password + "\n")
    subprocess.run(
        [str(ANSIBLE_VAULT), "encrypt", str(vault), "--vault-password-file", str(pw)],
        check=True,
        capture_output=True,
        timeout=120,
        cwd=root,
        env=hermetic_env(root),
    )
    return vault, pw


def vault_env(pi: Path, pi_pw: Path, vm: Path, vm_pw: Path) -> dict[str, str]:
    return {
        # ansible-vault's directory goes LAST so `python3` stays the plain system one
        # (no PyYAML: exercises the fallback parser and Python 3.9 compatibility).
        "PATH": f"{BASE_PATH}:{ANSIBLE_VAULT.parent}",
        "ANSIBLE_CONFIG": hermetic_env(pi.parents[4])["ANSIBLE_CONFIG"],
        "VAULT_PI": str(pi),
        "VAULT_VM": str(vm),
        "VAULT_PI_PASS_FILE": str(pi_pw),
        "VAULT_VM_PASS_FILE": str(vm_pw),
    }


# ------------------------------------------------------------------ pure logic
def test_compare_values_reports_match_mismatch_and_missing_per_key():
    left = {"a": "1", "b": "2", "only_pi": "x"}
    right = {"a": "1", "b": "3", "only_vm": "y"}

    result = compare_values(["a", "b", "only_pi", "only_vm", "nowhere"], left, right)

    assert result == [
        ("a", MATCH, ""),
        ("b", MISMATCH, ""),
        ("only_pi", MISMATCH, "missing in vm"),
        ("only_vm", MISMATCH, "missing in pi"),
        ("nowhere", MISMATCH, "missing in pi,vm"),
    ]


def test_compare_values_treats_an_empty_string_as_a_value_not_as_missing():
    assert compare_values(["k"], {"k": ""}, {"k": ""}) == [("k", MATCH, "")]
    assert compare_values(["k"], {"k": ""}, {"k": "x"}) == [("k", MISMATCH, "")]


def test_trailing_whitespace_differences_are_mismatches():
    assert compare_values(["k"], {"k": "abc"}, {"k": "abc "}) == [("k", MISMATCH, "")]


FLAT_VAULT = """\
---
# comment
plain: abc def  # trailing comment
dq: "quoted \\"inner\\" \\\\ value"
sq: 'it''s'
block: |
  line one
  line two

folded: >
  a
  b
n: 42
"""


def test_flat_parser_understands_the_shapes_in_vault_yml_example():
    parsed = _parse_flat(FLAT_VAULT)

    assert parsed == {
        "plain": "abc def",
        "dq": 'quoted "inner" \\ value',
        "sq": "it's",
        "block": "line one\nline two",
        "folded": "a b",
        "n": "42",
    }


@pytest.mark.parametrize("parse", [parse_top_level, _parse_flat])
def test_quoting_style_does_not_change_the_parsed_value(parse):
    text = "a: \"p@ss w0rd\"\nb: 'p@ss w0rd'\nc: p@ss w0rd\n"

    parsed = parse(text)

    assert parsed == {"a": "p@ss w0rd", "b": "p@ss w0rd", "c": "p@ss w0rd"}


def test_run_uses_the_injected_viewer_for_both_vaults():
    seen = []

    def viewer(path: Path, pw: Path | None) -> str:
        seen.append((path.name, pw))
        return "k: v\n"

    result = run(["k"], Path("pi.yml"), Path("vm.yml"), Path("p1"), Path("p2"), viewer)

    assert result == [("k", MATCH, "")]
    assert seen == [("pi.yml", Path("p1")), ("vm.yml", Path("p2"))]


def test_run_propagates_viewer_failure():
    def viewer(path: Path, pw: Path | None) -> str:
        raise VaultError("boom")

    with pytest.raises(VaultError, match="boom"):
        run(["k"], Path("a"), Path("b"), viewer=viewer)


# ------------------------------------------------- real ansible-vault, scratch data
@needs_ansible_vault
def test_cli_prints_only_verdicts_and_exits_1_on_any_mismatch(tmp_path):
    pi, pi_pw = make_vault(
        tmp_path / "pi",
        f'same: "{SECRET_A}"\ndiffers: "{SECRET_A}"\nonly_pi: "{SECRET_A}"\n',
    )
    vm, vm_pw = make_vault(
        tmp_path / "vm",
        f"same: '{SECRET_A}'\ndiffers: \"{SECRET_B}\"\n",
        password="a-different-throwaway",
    )

    proc = run_tool(
        "vault-hash-compare.sh",
        "same",
        "differs",
        "only_pi",
        env=vault_env(pi, pi_pw, vm, vm_pw),
        cwd=tmp_path,
    )

    assert proc.returncode == 1
    assert proc.stdout.splitlines() == ["same: match", "differs: MISMATCH", "only_pi: MISMATCH"]
    assert "only_pi: missing in vm" in proc.stderr
    for secret in (SECRET_A, SECRET_B, "s3cr3t"):
        assert secret not in proc.stdout + proc.stderr


@needs_ansible_vault
def test_cli_exits_0_when_every_key_matches(tmp_path):
    body = f'k1: "{SECRET_A}"\nk2: "{SECRET_B}"\n'
    pi, pi_pw = make_vault(tmp_path / "pi", body)
    vm, vm_pw = make_vault(tmp_path / "vm", body)

    proc = run_tool(
        "vault-hash-compare.sh", "k1", "k2", env=vault_env(pi, pi_pw, vm, vm_pw), cwd=tmp_path
    )

    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.splitlines() == ["k1: match", "k2: match"]
    assert SECRET_A not in proc.stdout + proc.stderr


@needs_ansible_vault
def test_cli_wrong_password_exits_2_with_empty_stdout_and_no_secret(tmp_path):
    pi, _ = make_vault(tmp_path / "pi", f'k: "{SECRET_A}"\n')
    vm, vm_pw = make_vault(tmp_path / "vm", f'k: "{SECRET_A}"\n')
    wrong = tmp_path / "wrong-pw"
    wrong.write_text("not-the-password\n")

    proc = run_tool("vault-hash-compare.sh", "k", env=vault_env(pi, wrong, vm, vm_pw), cwd=tmp_path)

    assert proc.returncode == 2
    assert proc.stdout == ""
    assert "ansible-vault view" in proc.stderr
    assert SECRET_A not in proc.stderr


def test_cli_without_keys_exits_2_with_usage():
    proc = run_tool("vault-hash-compare.sh")

    assert proc.returncode == 2
    assert "usage" in proc.stderr


# ------------------------------------------------------- unterminated quotes (F-5)
@pytest.mark.parametrize(
    ("line", "message"),
    [
        ("k: 'unterminated", r"unterminated single-quoted value for key 'k'"),
        ("k: '", r"unterminated single-quoted value for key 'k'"),
        ("k: 'ends with escaped quote''", r"unterminated single-quoted value for key 'k'"),
        ('k: "unterminated', r"cannot parse double-quoted value for key 'k'"),
        ('k: "', r"cannot parse double-quoted value for key 'k'"),
        ('k: "ends with escaped quote\\"', r"cannot parse double-quoted value for key 'k'"),
    ],
)
def test_flat_parser_rejects_an_unterminated_quote_instead_of_parsing_it_as_empty(line, message):
    with pytest.raises(VaultError, match=message):
        _parse_flat(f"first: ok\n{line}\nlast: ok\n")


def test_flat_parser_keeps_a_single_quoted_value_with_a_quote_in_the_trailing_comment():
    assert _parse_flat("k: 'a b'  # it's fine\n") == {"k": "a b"}
    assert _parse_flat("k: 'a''b' # x'\n") == {"k": "a'b"}
    assert _parse_flat("k: ''\n") == {"k": ""}


# ------------------------------------------- invalid YAML must not leak the secret (F-4)
LEAKY = f"token: {SECRET_A}: more\n"


def test_invalid_yaml_error_does_not_quote_the_secret_line_with_pyyaml(capsys):
    pytest.importorskip("yaml")

    with pytest.raises(VaultError) as info:
        parse_top_level(LEAKY)

    assert str(info.value) == "decrypted vault is not valid YAML (details withheld)"
    assert info.value.__cause__ is None
    assert info.value.__suppress_context__  # `from None`: no chained traceback quoting the line
    captured = capsys.readouterr()
    assert SECRET_A not in captured.out + captured.err


def test_invalid_yaml_without_pyyaml_never_prints_the_secret(monkeypatch, capsys):
    monkeypatch.setitem(sys.modules, "yaml", None)  # `import yaml` raises ImportError

    parsed = parse_top_level(LEAKY)

    assert parsed == {"token": f"{SECRET_A}: more"}  # lenient flat fallback, nothing raised
    captured = capsys.readouterr()
    assert SECRET_A not in captured.out + captured.err


def _fake_ansible_vault(root: Path, plaintext: str) -> dict[str, str]:
    """Env for the CLI whose `ansible-vault view` just prints ``plaintext``."""
    bindir = root / "bin"
    bindir.mkdir()
    (root / "plain.txt").write_text(plaintext)
    script = bindir / "ansible-vault"
    script.write_text(f'#!/bin/sh\ncat "{root}/plain.txt"\n')
    script.chmod(0o755)
    vaults = []
    for side in ("pi", "vm"):
        vault = root / side / VAULT_REL
        vault.parent.mkdir(parents=True)
        vault.write_text("ignored: by the fake\n")
        vaults.append(str(vault))
    return {
        "PATH": f"{bindir}:{BASE_PATH}",
        "ANSIBLE_CONFIG": hermetic_env(root)["ANSIBLE_CONFIG"],
        "VAULT_PI": vaults[0],
        "VAULT_VM": vaults[1],
    }


def test_cli_invalid_yaml_with_pyyaml_exits_2_and_prints_no_secret(tmp_path):
    yaml = pytest.importorskip("yaml")
    env = _fake_ansible_vault(tmp_path, LEAKY)
    env["PYTHONPATH"] = str(Path(yaml.__file__).parent.parent)

    proc = run_tool("vault-hash-compare.sh", "token", env=env, cwd=tmp_path)

    assert proc.returncode == 2
    assert proc.stdout == ""
    assert "not valid YAML" in proc.stderr
    assert SECRET_A not in proc.stdout + proc.stderr
    assert "Traceback" not in proc.stderr


def test_cli_invalid_yaml_without_pyyaml_prints_no_secret(tmp_path):
    env = _fake_ansible_vault(tmp_path, LEAKY)  # system python3 has no PyYAML here
    probe = subprocess.run(
        ["/usr/bin/env", "python3", "-c", "import yaml"],
        env={"PATH": BASE_PATH},
        capture_output=True,
        check=False,
        timeout=60,
    )
    if probe.returncode == 0:
        pytest.skip("the system python3 has PyYAML; the fallback path cannot be exercised")

    proc = run_tool("vault-hash-compare.sh", "token", env=env, cwd=tmp_path)

    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == "token: match\n"
    assert SECRET_A not in proc.stdout + proc.stderr


# ---------------------------------------- the repo's .vault_pass.sh / `op` must be unreachable
def _canary_repo(root: Path) -> tuple[Path, Path]:
    """A fake playbook dir like the real one plus an `op` canary that records any call."""
    repo, bindir = root / "fake-repo", root / "canary-bin"
    repo.mkdir()
    bindir.mkdir()
    marker = root / "canary-called"
    op = bindir / "op"
    op.write_text(f'#!/bin/sh\necho "$@" >> "{marker}"\necho leaked-password\n')
    op.chmod(0o755)
    script = repo / ".vault_pass.sh"
    script.write_text(f'#!/bin/sh\n"{op}" read op://x/y\n')
    script.chmod(0o755)
    (repo / "ansible.cfg").write_text("[defaults]\nvault_password_file = .vault_pass.sh\n")
    return repo, marker


@needs_ansible_vault
def test_make_vault_never_reaches_a_cwd_ansible_cfg_or_its_password_script(tmp_path, monkeypatch):
    repo, marker = _canary_repo(tmp_path)
    monkeypatch.chdir(repo)  # like pytest started inside ops-de-wahlberger-dev
    monkeypatch.setenv("ANSIBLE_VAULT_PASSWORD_FILE", str(repo / ".vault_pass.sh"))

    vault, _ = make_vault(tmp_path / "v", f'k: "{SECRET_A}"\n')

    assert vault.read_text().startswith("$ANSIBLE_VAULT;")
    assert not marker.exists(), "the repo's password script (op) was executed"


def test_hermetic_env_drops_inherited_vault_settings_and_points_at_an_empty_cfg(
    tmp_path, monkeypatch
):
    monkeypatch.setenv("ANSIBLE_VAULT_PASSWORD_FILE", "/real/script")
    monkeypatch.setenv("ANSIBLE_VAULT_IDENTITY_LIST", "x@/real/script")

    env = hermetic_env(tmp_path)

    assert "ANSIBLE_VAULT_PASSWORD_FILE" not in env
    assert "ANSIBLE_VAULT_IDENTITY_LIST" not in env
    assert Path(env["ANSIBLE_CONFIG"]).parent == tmp_path
    assert Path(env["ANSIBLE_CONFIG"]).read_text() == ""


def test_cli_announces_the_password_source_on_stderr_without_a_password_file(tmp_path):
    env = _fake_ansible_vault(tmp_path, "k: v\n")
    env["VAULT_VM_PASS_FILE"] = str(tmp_path / "vm-pw")

    proc = run_tool("vault-hash-compare.sh", "k", env=env, cwd=tmp_path)

    assert proc.stdout == "k: match\n"
    lines = [ln for ln in proc.stderr.splitlines() if ln.startswith("vault-hash-compare: ")]
    assert any(
        "pi vault" in ln and "no VAULT_PI_PASS_FILE: ansible.cfg of" in ln for ln in lines
    ), proc.stderr
    # The directory named is the playbook dir (vault.yml's parents[4]), exactly.
    pi_line = [ln for ln in lines if "pi vault" in ln][0]
    assert pi_line.endswith(f"ansible.cfg of {tmp_path / 'pi'} decides (maybe a script)"), pi_line
    assert any("vm vault" in ln and f"password file {tmp_path / 'vm-pw'}" in ln for ln in lines), (
        proc.stderr
    )
