"""vault-pair-compare.sh: only `<label>: match|MISMATCH` is printed (scratch vaults only)."""

from __future__ import annotations

from pathlib import Path

import pytest
from conftest import BASE_PATH, run_tool
from test_vault_hash import (
    ANSIBLE_VAULT,
    SECRET_A,
    SECRET_B,
    VAULT_REL,
    hermetic_env,
    make_vault,
    needs_ansible_vault,
)
from vault_hash import MATCH, MISMATCH, VaultError
from vault_pair_cli import CLOUD_KEY, NAS_KEY, compare_pair, parse_spec

SCRIPT = "vault-pair-compare.sh"


def env_for(root, **extra):
    return {
        # ansible-vault's directory goes LAST so `python3` stays the plain system one
        "PATH": f"{BASE_PATH}:{ANSIBLE_VAULT.parent}",
        "ANSIBLE_CONFIG": hermetic_env(root)["ANSIBLE_CONFIG"],
        **extra,
    }


def no_leak(proc):
    out = proc.stdout + proc.stderr
    for secret in (SECRET_A, SECRET_B, "s3cr3t"):
        assert secret not in out


# ------------------------------------------------------------------ pure logic
def test_compare_pair_matches_equal_values_under_different_key_names():
    assert compare_pair({"a": "x"}, "a", {"b": "x"}, "b") == (MATCH, [])


def test_compare_pair_different_values_mismatch_without_missing_sides():
    assert compare_pair({"a": "x"}, "a", {"b": "y"}, "b") == (MISMATCH, [])


@pytest.mark.parametrize(
    ("left", "right", "missing"),
    [({}, {"b": "x"}, ["left"]), ({"a": "x"}, {}, ["right"]), ({}, {}, ["left", "right"])],
)
def test_compare_pair_missing_key_is_a_mismatch_naming_the_side(left, right, missing):
    assert compare_pair(left, "a", right, "b") == (MISMATCH, missing)


def test_compare_pair_empty_string_is_a_value_not_missing():
    assert compare_pair({"a": ""}, "a", {"b": ""}, "b") == (MATCH, [])


def test_parse_spec_splits_on_the_last_colon():
    assert parse_spec("/x/a:b/vault.yml:vault_key") == (Path("/x/a:b/vault.yml"), "vault_key")


@pytest.mark.parametrize("spec", ["nocolon", ":key", "path:", ""])
def test_parse_spec_rejects_malformed_specs(spec):
    with pytest.raises(VaultError, match=r"expected <vault\.yml>:<key>"):
        parse_spec(spec)


# ------------------------------------------------- real ansible-vault, scratch data
@needs_ansible_vault
def test_pair_match_prints_label_only_and_exits_0(tmp_path):
    left, lpw = make_vault(tmp_path / "l", f'name_a: "{SECRET_A}"\n')
    right, rpw = make_vault(tmp_path / "r", f"name_b: '{SECRET_A}'\n", password="other-throwaway")
    env = env_for(tmp_path, VAULT_LEFT_PASS_FILE=str(lpw), VAULT_RIGHT_PASS_FILE=str(rpw))

    proc = run_tool(SCRIPT, f"{left}:name_a", f"{right}:name_b", "my-label", env=env, cwd=tmp_path)

    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == "my-label: match\n"
    no_leak(proc)


@needs_ansible_vault
def test_pair_mismatch_exits_1_with_default_label(tmp_path):
    left, lpw = make_vault(tmp_path / "l", f'name_a: "{SECRET_A}"\n')
    right, rpw = make_vault(tmp_path / "r", f'name_b: "{SECRET_B}"\n')
    env = env_for(tmp_path, VAULT_LEFT_PASS_FILE=str(lpw), VAULT_RIGHT_PASS_FILE=str(rpw))

    proc = run_tool(SCRIPT, f"{left}:name_a", f"{right}:name_b", env=env, cwd=tmp_path)

    assert proc.returncode == 1
    assert proc.stdout == "name_a vs name_b: MISMATCH\n"
    no_leak(proc)


@needs_ansible_vault
def test_pair_missing_key_is_a_mismatch_naming_only_the_side(tmp_path):
    left, lpw = make_vault(tmp_path / "l", f'name_a: "{SECRET_A}"\n')
    right, rpw = make_vault(tmp_path / "r", f'other: "{SECRET_A}"\n')
    env = env_for(tmp_path, VAULT_LEFT_PASS_FILE=str(lpw), VAULT_RIGHT_PASS_FILE=str(rpw))

    proc = run_tool(SCRIPT, f"{left}:name_a", f"{right}:name_b", "lbl", env=env, cwd=tmp_path)

    assert proc.returncode == 1
    assert proc.stdout == "lbl: MISMATCH\n"
    assert "lbl: missing in right" in proc.stderr
    no_leak(proc)


@needs_ansible_vault
def test_pair_wrong_password_exits_2_with_empty_stdout(tmp_path):
    left, _ = make_vault(tmp_path / "l", f'a: "{SECRET_A}"\n')
    right, rpw = make_vault(tmp_path / "r", f'b: "{SECRET_A}"\n')
    wrong = tmp_path / "wrong"
    wrong.write_text("nope\n")
    env = env_for(tmp_path, VAULT_LEFT_PASS_FILE=str(wrong), VAULT_RIGHT_PASS_FILE=str(rpw))

    proc = run_tool(SCRIPT, f"{left}:a", f"{right}:b", env=env, cwd=tmp_path)

    assert proc.returncode == 2
    assert proc.stdout == ""
    assert "ansible-vault view" in proc.stderr
    no_leak(proc)


@pytest.mark.parametrize(
    "args", [(), ("only-one:k",), ("a:k", "b:k", "l", "extra"), ("--cloud-nas", "x"), ("--bogus",)]
)
def test_usage_errors_exit_2(args):
    proc = run_tool(SCRIPT, *args)

    assert proc.returncode == 2
    assert "usage" in proc.stderr
    assert proc.stdout == ""


def test_malformed_spec_exits_2_without_traceback():
    proc = run_tool(SCRIPT, "nocolon", "b:k")

    assert proc.returncode == 2
    assert "expected <vault.yml>:<key>" in proc.stderr
    assert "Traceback" not in proc.stderr


# ------------------------------------------------------------------- --cloud-nas
@needs_ansible_vault
def test_cloud_nas_match_with_env_overrides(tmp_path):
    cloud, cpw = make_vault(tmp_path / "c", f'{CLOUD_KEY}: "{SECRET_A}"\n')
    nas, npw = make_vault(tmp_path / "n", f'{NAS_KEY}: "{SECRET_A}"\n', password="other")
    env = env_for(
        tmp_path,
        VAULT_CLOUD=str(cloud),
        VAULT_NAS=str(nas),
        VAULT_CLOUD_PASS_FILE=str(cpw),
        VAULT_NAS_PASS_FILE=str(npw),
    )

    proc = run_tool(SCRIPT, "--cloud-nas", env=env, cwd=tmp_path)

    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == "restic_rest_password: match\n"
    assert f"cloud vault {cloud}: password file {cpw}" in proc.stderr
    assert f"nas vault {nas}: password file {npw}" in proc.stderr
    no_leak(proc)


@needs_ansible_vault
def test_cloud_nas_mismatch_exits_1(tmp_path):
    cloud, cpw = make_vault(tmp_path / "c", f'{CLOUD_KEY}: "{SECRET_A}"\n')
    nas, npw = make_vault(tmp_path / "n", f'{NAS_KEY}: "{SECRET_B}"\n')
    env = env_for(
        tmp_path,
        VAULT_CLOUD=str(cloud),
        VAULT_NAS=str(nas),
        VAULT_CLOUD_PASS_FILE=str(cpw),
        VAULT_NAS_PASS_FILE=str(npw),
    )

    proc = run_tool(SCRIPT, "--cloud-nas", env=env, cwd=tmp_path)

    assert proc.returncode == 1
    assert proc.stdout == "restic_rest_password: MISMATCH\n"
    no_leak(proc)


@needs_ansible_vault
def test_cloud_nas_missing_key_names_only_the_nas_side(tmp_path):
    cloud, cpw = make_vault(tmp_path / "c", f'{CLOUD_KEY}: "{SECRET_A}"\n')
    nas, npw = make_vault(tmp_path / "n", f'unrelated: "{SECRET_A}"\n')
    env = env_for(
        tmp_path,
        VAULT_CLOUD=str(cloud),
        VAULT_NAS=str(nas),
        VAULT_CLOUD_PASS_FILE=str(cpw),
        VAULT_NAS_PASS_FILE=str(npw),
    )

    proc = run_tool(SCRIPT, "--cloud-nas", env=env, cwd=tmp_path)

    assert proc.returncode == 1
    assert proc.stdout == "restic_rest_password: MISMATCH\n"
    assert "restic_rest_password: missing in nas" in proc.stderr
    assert "missing in cloud" not in proc.stderr
    no_leak(proc)


def test_cloud_nas_announces_ansible_cfg_source_without_password_files(tmp_path):
    """No password file: stderr names the playbook dir; a fake ansible-vault serves the data."""
    bindir = tmp_path / "bin"
    bindir.mkdir()
    plain = tmp_path / "plain.txt"
    plain.write_text(f"{CLOUD_KEY}: v\n{NAS_KEY}: v\n")
    fake = bindir / "ansible-vault"
    fake.write_text(f'#!/bin/sh\ncat "{plain}"\n')
    fake.chmod(0o755)
    paths = {}
    for side in ("cloud", "nas"):
        vault = tmp_path / side / VAULT_REL
        vault.parent.mkdir(parents=True)
        vault.write_text("ignored\n")
        paths[side] = vault
    env = {
        "PATH": f"{bindir}:{BASE_PATH}",
        "ANSIBLE_CONFIG": hermetic_env(tmp_path)["ANSIBLE_CONFIG"],
        "VAULT_CLOUD": str(paths["cloud"]),
        "VAULT_NAS": str(paths["nas"]),
    }

    proc = run_tool(SCRIPT, "--cloud-nas", env=env, cwd=tmp_path)

    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == "restic_rest_password: match\n"
    assert f"ansible.cfg of {tmp_path / 'cloud'} decides (maybe a script)" in proc.stderr
    assert f"ansible.cfg of {tmp_path / 'nas'} decides (maybe a script)" in proc.stderr
    assert "no VAULT_CLOUD_PASS_FILE" in proc.stderr
