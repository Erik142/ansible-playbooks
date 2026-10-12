"""vault-copy-keys.sh: copies values under new key names, prints names only (scratch vaults)."""

from __future__ import annotations

import importlib.util
import io
import os
import signal
import stat
import subprocess
import sys
import time
from pathlib import Path

import pytest
from conftest import BASE_PATH, TOOLS, run_tool
from test_vault_hash import (
    ANSIBLE_VAULT,
    SECRET_A,
    SECRET_B,
    hermetic_env,
    make_vault,
    needs_ansible_vault,
)

VENV_PY = ANSIBLE_VAULT.parent / "python" if ANSIBLE_VAULT else None


def _venv_site_packages() -> str | None:
    """PyYAML lives only in the ansible venv; borrow it for the in-process tests (appended last)."""
    if VENV_PY is None or not VENV_PY.exists():
        return None
    probe = subprocess.run(
        [
            str(VENV_PY),
            "-c",
            "import os, yaml; print(os.path.dirname(os.path.dirname(yaml.__file__)))",
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=60,
    )
    return probe.stdout.strip() if probe.returncode == 0 else None


try:
    import yaml  # noqa: F401
except ImportError:
    _site = _venv_site_packages()
    if _site:
        sys.path.append(_site)

needs_yaml = pytest.mark.skipif(
    importlib.util.find_spec("yaml") is None,
    reason="no PyYAML in this python or the ansible venv",
)

from vault_copy import (  # noqa: E402
    CopyError,
    CopySpec,
    Refused,
    _check_others_unchanged,
    _check_parses,
    backup_path,
    check_ciphertext,
    check_markers,
    copy_keys,
    decrypt_exact,
    parse_copy_spec,
    set_key,
    write_atomic,
)
from vault_copy_cli import OPS_TO_NAS  # noqa: E402
from vault_hash import VaultError  # noqa: E402

SCRIPT = "vault-copy-keys.sh"
DST_PLAIN = "---\n# keep me\nzeta: \"z\"\nalpha: 'a'   # trailing\n\nblock: |\n  l1\n  l2\n"
DST_PW = "dst-throwaway"


def env_for(root, **extra):
    return {
        # ansible-vault's directory goes LAST so `python3` stays the plain system one
        "PATH": f"{BASE_PATH}:{ANSIBLE_VAULT.parent}",
        "ANSIBLE_CONFIG": hermetic_env(root)["ANSIBLE_CONFIG"],
        "VAULT_COPY_PYTHON": str(VENV_PY),  # the only python with PyYAML
        **extra,
    }


def no_leak(proc):
    out = proc.stdout + proc.stderr
    for secret in (SECRET_A, SECRET_B, "s3cr3t", DST_PW, "throwaway-1"):
        assert secret not in out


def plain_of(vault: Path, pw: Path) -> str:
    proc = subprocess.run(
        [
            str(ANSIBLE_VAULT),
            "decrypt",
            "--output",
            "-",
            str(vault),
            "--vault-password-file",
            pw,
        ],
        capture_output=True,
        check=True,
        timeout=120,
        env=hermetic_env(vault.parents[4]),
        cwd=vault.parents[4],
    )
    return proc.stdout.decode()


def setup(tmp_path, src_plain=None, dst_plain=DST_PLAIN):
    src_plain = src_plain if src_plain is not None else f'a: "{SECRET_A}"\nb: "{SECRET_B}"\n'
    src, spw = make_vault(tmp_path / "s", src_plain)
    dst, dpw = make_vault(tmp_path / "d", dst_plain, password=DST_PW)
    env = env_for(tmp_path, VAULT_SRC_PASS_FILE=str(spw), VAULT_DST_PASS_FILE=str(dpw))
    return src, dst, dpw, env


def leftovers(vault: Path) -> list[str]:
    return sorted(p.name for p in vault.parent.iterdir() if p.name != vault.name)


# ------------------------------------------------------------------ pure logic
def test_set_key_appends_with_json_quoting_and_keeps_existing_text():
    text = "# c\nk: 'v'\n"

    assert set_key(text, "n", 'p"w\\é') == text + 'n: "p\\"w\\\\é"\n'


def test_set_key_adds_the_missing_trailing_newline_before_appending():
    assert set_key("k: v", "n", "x") == 'k: v\nn: "x"\n'


def test_set_key_replaces_only_its_line_and_block_continuation():
    text = "a: 1\nn: |\n  old1\n\n  old2\n\nz: 2\n"

    assert set_key(text, "n", "new") == 'a: 1\nn: "new"\n\nz: 2\n'


def test_set_key_does_not_confuse_a_key_with_the_same_prefix():
    assert set_key("nn: 1\n", "n", "x") == 'nn: 1\nn: "x"\n'


def test_set_key_rejects_a_duplicated_key():
    with pytest.raises(CopyError, match="more than once"):
        set_key("n: 1\nn: 2\n", "n", "x")


def test_parse_copy_spec_splits_path_key_and_destination():
    assert parse_copy_spec("/x/a:b/vault.yml:src_key=dst_key") == CopySpec(
        Path("/x/a:b/vault.yml"), "src_key", "dst_key"
    )


@pytest.mark.parametrize("spec", ["", "v.yml:k", "v.yml=d", ":k=d", "v.yml:k=", "v.yml:1k=d"])
def test_parse_copy_spec_rejects_malformed_specs(spec):
    with pytest.raises(CopyError, match=r"expected <vault\.yml>:<src-key>=<dst-key>"):
        parse_copy_spec(spec)


def test_write_atomic_keeps_mode_and_leaves_no_temp_file(tmp_path):
    target = tmp_path / "f.yml"
    target.write_bytes(b"old")
    target.chmod(0o640)

    write_atomic(target, b"new")

    assert target.read_bytes() == b"new"
    assert target.stat().st_mode & 0o777 == 0o640
    assert [p.name for p in tmp_path.iterdir()] == ["f.yml"]


def test_write_atomic_failure_keeps_the_original_and_cleans_up(tmp_path, monkeypatch):
    target = tmp_path / "f.yml"
    target.write_bytes(b"old")
    monkeypatch.setattr(os, "fsync", lambda fd: (_ for _ in ()).throw(OSError("disk")))

    with pytest.raises(OSError, match="disk"):
        write_atomic(target, b"new")

    assert target.read_bytes() == b"old"
    assert [p.name for p in tmp_path.iterdir()] == ["f.yml"]


# ------------------------------------------------- real ansible-vault, scratch data
@needs_ansible_vault
def test_append_preserves_comments_and_order_byte_for_byte(tmp_path):
    src, dst, dpw, env = setup(tmp_path)

    proc = run_tool(SCRIPT, f"{src}:a=new_a", f"{src}:b=new_b", "--to", str(dst), env=env)

    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == "new_a: copied, match\nnew_b: copied, match\n"
    assert plain_of(dst, dpw) == (DST_PLAIN + f'new_a: "{SECRET_A}"\nnew_b: "{SECRET_B}"\n')
    assert "src vault" in proc.stderr
    assert f"dst vault {dst}: password file {dpw}" in proc.stderr
    no_leak(proc)


@needs_ansible_vault
def test_dst_without_trailing_newline_still_gets_a_clean_append(tmp_path):
    src, dst, dpw, env = setup(tmp_path, dst_plain="k: v")

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), env=env)

    assert proc.returncode == 0, proc.stderr
    assert plain_of(dst, dpw) == f'k: v\nnew_a: "{SECRET_A}"\n'


@needs_ansible_vault
def test_equal_value_already_present_is_a_noop_that_does_not_touch_the_file(tmp_path):
    src, dst, _dpw, env = setup(tmp_path, dst_plain=f"new_a: '{SECRET_A}'\n")
    before = dst.read_bytes()
    mtime = dst.stat().st_mtime_ns

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), env=env)

    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == "new_a: already present, equal\n"
    assert dst.read_bytes() == before
    assert dst.stat().st_mtime_ns == mtime
    no_leak(proc)


@needs_ansible_vault
def test_different_value_present_is_refused_and_nothing_is_written(tmp_path):
    src, dst, _dpw, env = setup(tmp_path, dst_plain=f'new_a: "{SECRET_B}"\n')
    before = dst.read_bytes()

    proc = run_tool(SCRIPT, f"{src}:a=new_a", f"{src}:b=new_b", "--to", str(dst), env=env)

    assert proc.returncode == 2
    assert proc.stdout == ""
    assert "REFUSED: new_a already present with a different value" in proc.stderr
    assert dst.read_bytes() == before
    no_leak(proc)


@needs_ansible_vault
def test_force_replaces_only_that_line(tmp_path):
    old = f'# top\nnew_a: "{SECRET_B}"\nkeep: 1\n'
    src, dst, dpw, env = setup(tmp_path, dst_plain=old)

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), "--force", env=env)

    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == "new_a: copied, match\n"
    assert plain_of(dst, dpw) == f'# top\nnew_a: "{SECRET_A}"\nkeep: 1\n'
    no_leak(proc)


@pytest.mark.parametrize(("src_plain", "word"), [("other: x\n", "missing"), ('a: ""\n', "empty")])
@needs_ansible_vault
def test_missing_or_empty_source_key_is_refused_naming_only_the_key(tmp_path, src_plain, word):
    src, dst, _dpw, env = setup(tmp_path, src_plain=src_plain)
    before = dst.read_bytes()

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), env=env)

    assert proc.returncode == 2
    assert f"source key a is {word}" in proc.stderr
    assert proc.stdout == ""
    assert dst.read_bytes() == before


@needs_ansible_vault
def test_dry_run_checks_everything_but_writes_nothing(tmp_path):
    src, dst, _dpw, env = setup(tmp_path)
    before = dst.read_bytes()
    mtime = dst.stat().st_mtime_ns

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), "--dry-run", env=env)

    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == "new_a: would copy (dry run, nothing written)\n"
    assert dst.read_bytes() == before
    assert dst.stat().st_mtime_ns == mtime
    assert leftovers(dst) == []  # no .bak, no temp file: the password file sits in the root
    no_leak(proc)


@needs_ansible_vault
def test_dry_run_still_refuses_a_different_present_value(tmp_path):
    src, dst, _dpw, env = setup(tmp_path, dst_plain=f'new_a: "{SECRET_B}"\n')

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), "--dry-run", env=env)

    assert proc.returncode == 2
    assert "REFUSED" in proc.stderr


@needs_ansible_vault
def test_write_leaves_no_temp_files_and_keeps_the_file_mode(tmp_path):
    src, dst, _dpw, env = setup(tmp_path)
    dst.chmod(0o640)
    siblings = leftovers(dst)

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), env=env)

    assert proc.returncode == 0, proc.stderr
    assert dst.stat().st_mode & 0o777 == 0o640
    assert leftovers(dst) == siblings


@needs_ansible_vault
def test_wrong_destination_password_exits_2_and_leaves_the_file(tmp_path):
    src, dst, _dpw, env = setup(tmp_path)
    wrong = tmp_path / "wrong"
    wrong.write_text("nope\n")
    before = dst.read_bytes()

    proc = run_tool(
        SCRIPT,
        f"{src}:a=new_a",
        "--to",
        str(dst),
        env={**env, "VAULT_DST_PASS_FILE": str(wrong)},
    )

    assert proc.returncode == 2
    assert proc.stdout == ""
    assert "ansible-vault decrypt" in proc.stderr
    assert dst.read_bytes() == before
    no_leak(proc)


@needs_ansible_vault
def test_wrong_source_password_exits_2(tmp_path):
    src, dst, _dpw, env = setup(tmp_path)
    wrong = tmp_path / "wrong"
    wrong.write_text("nope\n")

    proc = run_tool(
        SCRIPT,
        f"{src}:a=new_a",
        "--to",
        str(dst),
        env={**env, "VAULT_SRC_PASS_FILE": str(wrong)},
    )

    assert proc.returncode == 2
    assert "ansible-vault decrypt" in proc.stderr
    no_leak(proc)


# ----------------------------------------------------- verification and restore
@needs_ansible_vault
def test_failed_verification_restores_the_previous_file_and_exits_1(tmp_path, monkeypatch):
    src, dst, dpw, env = setup(tmp_path)
    monkeypatch.setenv("PATH", f"{os.environ['PATH']}:{ANSIBLE_VAULT.parent}")
    before = dst.read_bytes()
    calls = []

    def lying_decrypt(vault, pass_file):
        calls.append(vault)
        text = decrypt_exact(vault, pass_file)
        return text.replace(SECRET_A, "tampered") if len(calls) > 1 else text

    out, err = io.StringIO(), io.StringIO()
    code = copy_keys(
        [CopySpec(src, "a", "new_a")],
        dst,
        src_pass=Path(env["VAULT_SRC_PASS_FILE"]),
        dst_pass=dpw,
        out=out,
        err=err,
        decrypt=lying_decrypt,
    )

    assert code == 1
    assert out.getvalue() == "new_a: MISMATCH\n"
    assert "previous content restored" in err.getvalue()
    assert dst.read_bytes() == before
    assert leftovers(dst) == [backup_path(dst).name]  # kept after a failure
    assert backup_path(dst).read_bytes() == before
    for text in (out.getvalue(), err.getvalue()):
        assert SECRET_A not in text


def test_edited_text_not_holding_the_new_value_is_refused():
    with pytest.raises(CopyError, match="nothing written"):
        _check_parses("a: 1\n", {"n": "x"})


def test_a_duplicate_destination_key_is_rejected(tmp_path):
    with pytest.raises(CopyError, match="given twice"):
        copy_keys(
            [CopySpec(tmp_path, "a", "d"), CopySpec(tmp_path, "b", "d")],
            tmp_path / "x.yml",
        )


def test_refused_is_a_copy_error():
    assert issubclass(Refused, CopyError)


# ------------------------------------------------------------------ --ops-to-nas
@needs_ansible_vault
def test_ops_to_nas_copies_both_restic_secrets_with_env_overrides(tmp_path):
    src_key1, dst_key1 = OPS_TO_NAS[0]
    src_key2, dst_key2 = OPS_TO_NAS[1]
    ops, opw = make_vault(tmp_path / "o", f'{src_key1}: "{SECRET_A}"\n{src_key2}: "{SECRET_B}"\n')
    nas, npw = make_vault(tmp_path / "n", DST_PLAIN, password=DST_PW)
    env = env_for(
        tmp_path,
        VAULT_OPS=str(ops),
        VAULT_NAS=str(nas),
        VAULT_OPS_PASS_FILE=str(opw),
        VAULT_NAS_PASS_FILE=str(npw),
    )

    proc = run_tool(SCRIPT, "--ops-to-nas", env=env)

    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == (
        "vault_restic_server_ops_htpasswd_password: copied, match\n"
        "vault_restic_server_ops_repo_password: copied, match\n"
    )
    assert plain_of(nas, npw) == DST_PLAIN + (
        f'{dst_key1}: "{SECRET_A}"\n{dst_key2}: "{SECRET_B}"\n'
    )
    assert f"ops vault {ops}: password file {opw}" in proc.stderr
    assert f"nas vault {nas}: password file {npw}" in proc.stderr
    no_leak(proc)


@needs_ansible_vault
def test_ops_to_nas_announces_ansible_cfg_source_without_password_files(tmp_path):
    ops = tmp_path / "o/inventories/production/group_vars/all/vault.yml"
    ops.parent.mkdir(parents=True)
    ops.write_text("x")
    missing_nas = tmp_path / "n/inventories/production/group_vars/all/vault.yml"
    env = {
        "PATH": BASE_PATH,
        "VAULT_COPY_PYTHON": str(VENV_PY),
        "VAULT_OPS": str(ops),
        "VAULT_NAS": str(missing_nas),
    }

    proc = run_tool(SCRIPT, "--ops-to-nas", env=env)

    assert proc.returncode == 2
    assert f"destination vault missing: {missing_nas}" in proc.stderr
    assert f"ansible.cfg of {tmp_path / 'o'} decides (maybe a script)" in proc.stderr
    assert "no VAULT_NAS_PASS_FILE" in proc.stderr


@pytest.mark.parametrize(
    "args",
    [
        (),
        ("a.yml:k=d",),
        ("--to", "x.yml"),
        ("--ops-to-nas", "a.yml:k=d"),
        ("--ops-to-nas", "--to", "x"),
    ],
)
def test_usage_errors_exit_2(args):
    proc = run_tool(SCRIPT, *args)

    assert proc.returncode == 2
    assert "usage" in proc.stderr
    assert proc.stdout == ""


def test_malformed_spec_exits_2_without_traceback(tmp_path):
    proc = run_tool(SCRIPT, "nocolon", "--to", str(tmp_path / "d.yml"))

    assert proc.returncode == 2
    assert "expected <vault.yml>:<src-key>=<dst-key>" in proc.stderr
    assert "Traceback" not in proc.stderr


# ============================================================ review-fix tests
SHIM = """#!/bin/sh
n=$(cat "$SHIM_COUNT" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$SHIM_COUNT"
if [ "$n" = "$SHIM_FAIL_AT" ]; then
  if [ "$SHIM_MODE" = empty ]; then exit 0; fi
  if [ "$SHIM_MODE" = sleep ]; then exec sleep 30; fi
  if [ "$SHIM_MODE" = notfound ]; then exit 127; fi
  echo "boom" >&2
  exit 1
fi
exec "$REAL_ANSIBLE_VAULT" "$@"
"""


def shim_env(tmp_path, env, fail_at, mode="fail"):
    """PATH-first `ansible-vault` wrapper that fails (or prints nothing) on call number N."""
    bindir = tmp_path / "shimbin"
    bindir.mkdir()
    shim = bindir / "ansible-vault"
    shim.write_text(SHIM)
    shim.chmod(0o755)
    count = tmp_path / "shim-count"
    return count, {
        **env,
        "PATH": f"{bindir}:{env['PATH']}",
        "SHIM_COUNT": str(count),
        "SHIM_FAIL_AT": str(fail_at),
        "SHIM_MODE": mode,
        "REAL_ANSIBLE_VAULT": str(ANSIBLE_VAULT),
    }


class VaultBoom(Exception):
    pass


@pytest.fixture
def vault_on_path(monkeypatch):
    monkeypatch.setenv("PATH", f"{os.environ['PATH']}:{ANSIBLE_VAULT.parent}")


# ------------------------------------------------------ MAJOR-1: write safety net
@needs_ansible_vault
def test_post_write_failure_restores_the_original_bytes_and_keeps_the_bak(tmp_path):
    src, dst, _dpw, env = setup(tmp_path)
    before = dst.read_bytes()
    count, env = shim_env(tmp_path, env, fail_at=4)  # 1 src, 2 dst, 3 encrypt, 4 re-read

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), env=env)

    assert count.read_text().strip() == "4"
    assert proc.returncode == 1
    assert proc.stdout == ""
    assert "modified and has been restored from the original bytes (verified)" in proc.stderr
    assert dst.read_bytes() == before
    bak = backup_path(dst)
    assert bak.read_bytes() == before
    assert stat.S_IMODE(bak.stat().st_mode) == 0o600
    assert leftovers(dst) == [bak.name]
    no_leak(proc)


@needs_ansible_vault
def test_empty_encrypt_output_writes_nothing_and_leaves_no_bak(tmp_path):
    src, dst, _dpw, env = setup(tmp_path)
    before = dst.read_bytes()
    mtime = dst.stat().st_mtime_ns
    count, env = shim_env(tmp_path, env, fail_at=3, mode="empty")

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), env=env)

    assert count.read_text().strip() == "3"
    assert proc.returncode == 2
    assert proc.stdout == ""
    assert "no valid Ansible Vault payload" in proc.stderr
    assert dst.read_bytes() == before
    assert dst.stat().st_mtime_ns == mtime
    assert leftovers(dst) == []


@needs_ansible_vault
def test_success_deletes_the_bak_and_prints_the_verdict(tmp_path):
    src, dst, _dpw, env = setup(tmp_path)
    original = dst.read_bytes()

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), env=env)

    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == "new_a: copied, match\n"
    assert dst.read_bytes() != original
    assert not backup_path(dst).exists()
    assert leftovers(dst) == []


@needs_ansible_vault
def test_existing_bak_blocks_the_run_and_stays_untouched(tmp_path):
    src, dst, _dpw, env = setup(tmp_path)
    before = dst.read_bytes()
    bak = backup_path(dst)
    bak.write_bytes(b"older backup")

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), env=env)

    assert proc.returncode == 2
    assert "already exists" in proc.stderr
    assert dst.read_bytes() == before
    assert bak.read_bytes() == b"older backup"


def _in_process(src, dst, dpw, env, **kwargs):
    out, err = io.StringIO(), io.StringIO()
    code = copy_keys(
        [CopySpec(src, "a", "new_a")],
        dst,
        src_pass=Path(env["VAULT_SRC_PASS_FILE"]),
        dst_pass=dpw,
        out=out,
        err=err,
        **kwargs,
    )
    return code, out.getvalue(), err.getvalue()


@needs_ansible_vault
@needs_yaml
def test_interrupt_after_the_rename_restores_and_reports(tmp_path, vault_on_path):
    src, dst, dpw, env = setup(tmp_path)
    before = dst.read_bytes()
    calls = []

    def interrupted(vault, pass_file):
        calls.append(vault)
        if len(calls) > 1:
            raise KeyboardInterrupt
        return decrypt_exact(vault, pass_file)

    code, out, err = _in_process(src, dst, dpw, env, decrypt=interrupted)

    assert code == 1
    assert out == ""
    assert "KeyboardInterrupt" in err
    assert "restored from the original bytes (verified)" in err
    assert dst.read_bytes() == before


@needs_ansible_vault
@needs_yaml
def test_failed_restore_exits_3_with_the_manual_recovery_command(tmp_path, vault_on_path):
    src, dst, dpw, env = setup(tmp_path)
    before = dst.read_bytes()
    calls = []

    def failing(vault, pass_file):
        calls.append(vault)
        if len(calls) > 1:
            raise VaultBoom
        return decrypt_exact(vault, pass_file)

    def broken_restore(path, data):
        raise OSError("disk gone")

    code, out, err = _in_process(src, dst, dpw, env, decrypt=failing, restore=broken_restore)

    bak = backup_path(dst)
    assert code == 3
    assert out == ""
    assert "could NOT be restored" in err
    assert f"cp {bak} {dst}" in err
    assert f"git checkout -- {dst}" in err
    assert dst.read_bytes() != before  # the new cipher is in place, the .bak has the original
    assert bak.read_bytes() == before


@needs_ansible_vault
@needs_yaml
def test_write_failing_before_the_rename_reports_unchanged_and_drops_the_bak(
    tmp_path, vault_on_path
):
    src, dst, dpw, env = setup(tmp_path)
    before = dst.read_bytes()

    def no_write(path, data):
        raise OSError("read-only")

    code, out, err = _in_process(src, dst, dpw, env, write=no_write)

    assert code == 2
    assert out == ""
    assert "the vault file is unchanged (verified)" in err
    assert dst.read_bytes() == before
    assert leftovers(dst) == []


@pytest.mark.parametrize(
    "data",
    [
        b"",
        b"\n",
        b"$ANSIBLE_VAULT;1.1;AES256\n",
        b"not a vault " + b"ab" * 80,
        b"$ANSIBLE_VAULT;1.1;AES256\n" + b"zz" * 80,
        b"$ANSIBLE_VAULT;1.1;AES256\n6162",
    ],
)
def test_check_ciphertext_rejects_degenerate_output(data):
    with pytest.raises(CopyError, match="no valid Ansible Vault payload"):
        check_ciphertext(data)


def test_check_ciphertext_accepts_a_vault_shaped_payload():
    check_ciphertext(b"$ANSIBLE_VAULT;1.1;AES256\n" + (b"ab" * 40 + b"\n") * 3)


# ------------------------------------- MAJOR-3: exactly one secret, explicit config
def real_cfg_shape(tmp_path):
    """Scratch playbooks whose ansible.cfg names a script-less vault_password_file."""
    src, spw = make_vault(tmp_path / "s", f'a: "{SECRET_A}"\n')
    dst, dpw = make_vault(tmp_path / "d", DST_PLAIN, password=DST_PW)
    for root, pw in ((tmp_path / "s", spw), (tmp_path / "d", dpw)):
        (root / ".vault_pw").write_text(pw.read_text())
        (root / "ansible.cfg").write_text("[defaults]\nvault_password_file = .vault_pw\n")
    return src, dst, spw, dpw


@needs_ansible_vault
@pytest.mark.parametrize("with_files", [True, False], ids=["password-files", "cfg-only"])
def test_real_cfg_shape_works_with_and_without_password_files(tmp_path, with_files):
    src, dst, spw, dpw = real_cfg_shape(tmp_path)
    extra = {"VAULT_SRC_PASS_FILE": str(spw), "VAULT_DST_PASS_FILE": str(dpw)} if with_files else {}
    env = env_for(tmp_path, **extra)

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), env=env)

    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == "new_a: copied, match\n"
    assert plain_of(dst, dpw) == DST_PLAIN + f'new_a: "{SECRET_A}"\n'
    assert not backup_path(dst).exists()
    no_leak(proc)


@needs_ansible_vault
def test_stray_ansible_environment_variables_are_ignored(tmp_path):
    src, dst, spw, dpw = real_cfg_shape(tmp_path)
    env = env_for(
        tmp_path,
        VAULT_SRC_PASS_FILE=str(spw),
        VAULT_DST_PASS_FILE=str(dpw),
        ANSIBLE_CONFIG="/nonexistent/ansible.cfg",
        ANSIBLE_VAULT_PASSWORD_FILE="/nonexistent/pw",
        ANSIBLE_VAULT_IDENTITY_LIST="bogus@/nonexistent/pw",
        ANSIBLE_VAULT_ID_MATCH="True",
        ANSIBLE_VAULT_ENCRYPT_SALT="0123456789abcdef",
    )

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), env=env)

    assert proc.returncode == 0, proc.stderr
    assert plain_of(dst, dpw) == DST_PLAIN + f'new_a: "{SECRET_A}"\n'


@needs_ansible_vault
def test_missing_ansible_cfg_without_password_file_exits_2_naming_it(tmp_path):
    src, dst, _spw, _dpw = real_cfg_shape(tmp_path)
    (tmp_path / "d" / "ansible.cfg").unlink()
    before = dst.read_bytes()
    env = env_for(tmp_path)

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), env=env)

    assert proc.returncode == 2
    assert f"{tmp_path / 'd' / 'ansible.cfg'} is missing" in proc.stderr
    assert dst.read_bytes() == before


@needs_ansible_vault
@pytest.mark.parametrize("side", ["SRC", "DST"])
def test_executable_password_file_is_rejected(tmp_path, side):
    src, dst, _dpw, env = setup(tmp_path)
    before = dst.read_bytes()
    pw = Path(env[f"VAULT_{side}_PASS_FILE"])
    pw.chmod(0o755)

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), env=env)

    assert proc.returncode == 2
    assert f"password file {pw} is executable" in proc.stderr
    assert dst.read_bytes() == before
    assert leftovers(dst) == []


# --------------------------------------------- MAJOR-2: PyYAML and strict checks
@needs_ansible_vault
def test_without_pyyaml_and_no_venv_python_the_tool_exits_2(tmp_path):
    src, dst, _dpw, env = setup(tmp_path)
    before = dst.read_bytes()
    stub = tmp_path / "stub"
    stub.mkdir()
    (stub / "yaml.py").write_text("raise ImportError('stubbed out')\n")
    env = {**env, "PYTHONPATH": str(stub), "HOME": str(tmp_path / "nohome")}

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), env=env)

    assert proc.returncode == 2
    assert "PyYAML is required" in proc.stderr
    assert "ansible-bind9-venv" in proc.stderr
    assert dst.read_bytes() == before


@needs_ansible_vault
def test_without_pyyaml_the_tool_reexecs_under_the_ansible_venv_python(tmp_path):
    src, dst, dpw, env = setup(tmp_path)
    stub = tmp_path / "stub"
    stub.mkdir()
    (stub / "yaml.py").write_text("raise ImportError('stubbed out')\n")
    fake_py = tmp_path / "home/.pyenv/versions/ansible-bind9-venv/bin/python"
    fake_py.parent.mkdir(parents=True)
    fake_py.write_text(f'#!/bin/sh\nunset PYTHONPATH\nexec {VENV_PY} "$@"\n')
    fake_py.chmod(0o755)
    env = {**env, "PYTHONPATH": str(stub), "HOME": str(tmp_path / "home")}

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), env=env)

    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == "new_a: copied, match\n"
    assert plain_of(dst, dpw).endswith(f'new_a: "{SECRET_A}"\n')


@needs_ansible_vault
@pytest.mark.parametrize(
    "plain",
    [
        "k: 1\n...\n",
        "k: 1\n---\nj: 2\n",
        "---\nk: 1\n---\n",
        "k: 1\n--- # again\nj: 2\n",
        "# c\n---\n---\nk: 1\n",
        "k: 1\r\n...\r\n",
    ],
)
def test_document_markers_other_than_one_leading_dashes_are_rejected(tmp_path, plain):
    src, dst, _dpw, env = setup(tmp_path, dst_plain=plain)
    before = dst.read_bytes()

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), env=env)

    assert proc.returncode == 2
    assert "document marker" in proc.stderr
    assert proc.stdout == ""
    assert dst.read_bytes() == before
    assert leftovers(dst) == []


@needs_ansible_vault
@pytest.mark.parametrize("plain", ["---\nk: 1\n", "# c\n\n---\nk: 1\n"])
def test_one_leading_document_start_marker_is_fine(tmp_path, plain):
    src, dst, dpw, env = setup(tmp_path, dst_plain=plain)

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), env=env)

    assert proc.returncode == 0, proc.stderr
    assert plain_of(dst, dpw) == plain + f'new_a: "{SECRET_A}"\n'


@needs_ansible_vault
@pytest.mark.parametrize(
    "plain",
    ["new_a: 1\nnew_a: 2\n", '"new_a": 1\nnew_a: 2\n', 'new_a : 1\n"new_a": 2\n'],
)
def test_duplicate_destination_keys_are_refused_even_when_quoted(tmp_path, plain):
    src, dst, _dpw, env = setup(tmp_path, dst_plain=plain)
    before = dst.read_bytes()

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), "--force", env=env)

    assert proc.returncode == 2
    assert "appears more than once" in proc.stderr
    assert dst.read_bytes() == before


@needs_ansible_vault
@pytest.mark.parametrize("plain", ['"new_a": x\n', "'new_a': x\n", "new_a : x\n"])
def test_quoted_or_spaced_existing_key_counts_as_present(tmp_path, plain):
    src, dst, _dpw, env = setup(tmp_path, dst_plain=plain)
    before = dst.read_bytes()

    refused = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), env=env)
    forced = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), "--force", env=env)

    assert refused.returncode == 2
    assert "REFUSED: new_a already present with a different value" in refused.stderr
    assert forced.returncode == 2  # cannot safely locate a non-plain key line: edit by hand
    assert "not as a plain `new_a: value` line" in forced.stderr
    assert dst.read_bytes() == before
    assert leftovers(dst) == []


@needs_ansible_vault
def test_quoted_existing_key_with_an_equal_value_is_a_noop(tmp_path):
    src, dst, _dpw, env = setup(tmp_path, dst_plain=f'"new_a" : "{SECRET_A}"\n')
    before = dst.read_bytes()

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), env=env)

    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == "new_a: already present, equal\n"
    assert dst.read_bytes() == before


@needs_ansible_vault
def test_keep_block_without_trailing_newline_would_change_and_is_refused(tmp_path):
    src, dst, _dpw, env = setup(tmp_path, dst_plain="blk: |+\n  l1\n  l2")
    before = dst.read_bytes()

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), env=env)

    assert proc.returncode == 2
    assert "would change other keys" in proc.stderr
    assert dst.read_bytes() == before
    assert leftovers(dst) == []


@needs_ansible_vault
def test_keep_block_with_trailing_newlines_is_kept_exactly(tmp_path):
    plain = "blk: |+\n  l1\n\n"
    src, dst, dpw, env = setup(tmp_path, dst_plain=plain)

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), env=env)

    assert proc.returncode == 0, proc.stderr
    assert plain_of(dst, dpw) == plain + f'new_a: "{SECRET_A}"\n'


@needs_ansible_vault
@pytest.mark.parametrize(
    ("plain", "expected_tail"),
    [
        ("a: 1\r\nb: 2\r\n", f'new_a: "{SECRET_A}"\r\n'),
        ("a: 1\r\nb: 2", f'\r\nnew_a: "{SECRET_A}"\r\n'),
        ("a: 1\nb: 2", f'\nnew_a: "{SECRET_A}"\n'),
    ],
    ids=["crlf", "crlf-no-final-newline", "lf-no-final-newline"],
)
def test_line_endings_and_missing_final_newline_are_preserved(tmp_path, plain, expected_tail):
    src, dst, dpw, env = setup(tmp_path, dst_plain=plain)

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), env=env)

    assert proc.returncode == 0, proc.stderr
    assert plain_of(dst, dpw) == plain + expected_tail


@needs_ansible_vault
def test_inline_vault_tagged_values_are_carried_through_untouched(tmp_path):
    tagged = "tok: !vault |\n  $ANSIBLE_VAULT;1.1;AES256\n  " + "61" * 40 + "\n"
    plain = tagged + "k: v\n"
    src, dst, dpw, env = setup(tmp_path, dst_plain=plain)

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), env=env)

    assert proc.returncode == 0, proc.stderr
    assert plain_of(dst, dpw) == plain + f'new_a: "{SECRET_A}"\n'


# ------------------------------------------------------------- pure-logic additions
@pytest.mark.parametrize(
    ("text", "ok"),
    [
        ("", True),
        ("---\na: 1\n", True),
        ("# c\n---\na: 1\n", True),
        ("a: 1\n---\n", False),
        ("---\n---\n", False),
        ("a: 1\n...\n", False),
        ("a: 1\n--- x\n", False),
        ("a: |\n  ---\n", True),
        ("a: '---'\n", True),
    ],
)
def test_check_markers(text, ok):
    if ok:
        check_markers(text)
    else:
        with pytest.raises(CopyError, match="document marker"):
            check_markers(text)


def test_set_key_uses_crlf_when_the_text_does():
    assert set_key("a: 1\r\n", "n", "x") == 'a: 1\r\nn: "x"\r\n'


def test_set_key_does_not_split_on_unicode_line_separators():
    text = "a: 'x\u2028n: y'\n"

    assert set_key(text, "n", "z") == text + 'n: "z"\n'


def test_set_key_must_exist_refuses_to_append_instead_of_replacing():
    with pytest.raises(CopyError, match="not as a plain"):
        set_key('"n": 1\n', "n", "x", must_exist=True)


@needs_yaml
def test_other_keys_check_passes_when_only_the_copied_key_differs():
    _check_others_unchanged("a: 1\nn: 2\n", 'a: 1\nn: "x"\n', {"n"})


@needs_yaml
def test_other_keys_check_fails_when_another_key_changes():
    with pytest.raises(CopyError, match="other keys"):
        _check_others_unchanged("a: 1\nn: 2\n", 'a: 2\nn: "x"\n', {"n"})


# ------------------------------------------------------------ final-round fixes
@needs_ansible_vault
def test_dry_run_works_with_no_ansible_vault_on_path(tmp_path):
    src, dst, _dpw, env = setup(tmp_path)
    before = dst.read_bytes()
    env = {**env, "PATH": "/usr/bin:/bin"}  # only the venv python's own bin dir has the tool

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), "--dry-run", env=env)

    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == "new_a: would copy (dry run, nothing written)\n"
    assert dst.read_bytes() == before


@needs_ansible_vault
def test_a_path_shim_answering_127_falls_back_to_the_venv_ansible_vault(tmp_path):
    src, dst, dpw, env = setup(tmp_path)
    _count, env = shim_env(tmp_path, env, fail_at=1, mode="notfound")  # pyenv-shim like

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), env=env)

    assert proc.returncode == 0, proc.stderr
    assert plain_of(dst, dpw).endswith(f'new_a: "{SECRET_A}"\n')


@needs_ansible_vault
@needs_yaml
def test_no_ansible_vault_anywhere_exits_2_with_the_path_hint_and_writes_nothing(
    tmp_path, monkeypatch
):
    _src, dst, dpw, _env = setup(tmp_path)
    before = dst.read_bytes()
    pybin = tmp_path / "pybin"
    pybin.mkdir()
    monkeypatch.setenv("PATH", "/usr/bin:/bin")
    monkeypatch.setenv("HOME", str(tmp_path / "nohome"))
    monkeypatch.setattr(sys, "executable", str(pybin / "python"))
    monkeypatch.setattr(Path, "home", lambda: tmp_path / "nohome")

    with pytest.raises(VaultError) as exc:
        decrypt_exact(dst, dpw)

    assert str(exc.value) == (
        "ansible-vault not found; put $HOME/.pyenv/versions/ansible-bind9-venv/bin on PATH"
    )
    assert dst.read_bytes() == before
    assert leftovers(dst) == []


@needs_ansible_vault
def test_symlinked_destination_stays_a_link_and_the_target_is_updated(tmp_path):
    src, real, dpw, env = setup(tmp_path)
    link = tmp_path / "link.yml"
    link.symlink_to(real)

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(link), env=env)

    assert proc.returncode == 0, proc.stderr
    assert link.is_symlink()
    assert plain_of(real, dpw).endswith(f'new_a: "{SECRET_A}"\n')
    assert not backup_path(link).exists()
    assert leftovers(real) == []


@needs_ansible_vault
def test_symlinked_destination_is_restored_in_place_on_failure(tmp_path):
    src, real, _dpw, env = setup(tmp_path)
    before = real.read_bytes()
    link = tmp_path / "link.yml"
    link.symlink_to(real)
    _count, env = shim_env(tmp_path, env, fail_at=4)

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(link), env=env)

    assert proc.returncode == 1
    assert "restored from the original bytes (verified)" in proc.stderr
    assert link.is_symlink()
    assert real.read_bytes() == before
    assert backup_path(link) == backup_path(real)
    assert backup_path(real).read_bytes() == before


@needs_ansible_vault
def test_relative_vault_arguments_work_from_another_cwd(tmp_path):
    src, dst, dpw, env = setup(tmp_path)
    for root in (tmp_path / "s", tmp_path / "d"):
        (root / ".vault_pw").write_text(DST_PW + "\n" if root.name == "d" else "throwaway-1\n")
        (root / "ansible.cfg").write_text("[defaults]\nvault_password_file = .vault_pw\n")
    env = env_for(tmp_path)  # no password files: the playbooks' ansible.cfg decide
    rel_src = os.path.relpath(src, tmp_path)
    rel_dst = os.path.relpath(dst, tmp_path)

    proc = run_tool(SCRIPT, f"{rel_src}:a=new_a", "--to", rel_dst, env=env, cwd=tmp_path)

    assert proc.returncode == 0, proc.stderr
    assert plain_of(dst, dpw).endswith(f'new_a: "{SECRET_A}"\n')


@needs_ansible_vault
@pytest.mark.parametrize("side", ["SRC", "DST"])
def test_oversized_password_file_is_rejected(tmp_path, side):
    src, dst, _dpw, env = setup(tmp_path)
    before = dst.read_bytes()
    pw = Path(env[f"VAULT_{side}_PASS_FILE"])
    pw.write_text("x" * 5000 + "\n")

    proc = run_tool(SCRIPT, f"{src}:a=new_a", "--to", str(dst), env=env)

    assert proc.returncode == 2
    assert f"password file {pw} is larger than 4096 bytes" in proc.stderr
    assert dst.read_bytes() == before
    assert leftovers(dst) == []


@needs_ansible_vault
@pytest.mark.parametrize("sig", [signal.SIGTERM, signal.SIGHUP], ids=["SIGTERM", "SIGHUP"])
def test_termination_signal_during_verification_restores_the_vault(tmp_path, sig):
    src, dst, _dpw, env = setup(tmp_path)
    before = dst.read_bytes()
    count, env = shim_env(tmp_path, env, fail_at=4, mode="sleep")  # 4th call = re-read
    proc = subprocess.Popen(
        [str(TOOLS / SCRIPT), f"{src}:a=new_a", "--to", str(dst)],
        env={"HOME": str(Path.home()), **env},
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            if count.exists() and count.read_text().strip() == "4":
                break
            time.sleep(0.05)
        else:
            pytest.fail("the 4th ansible-vault call never started")
        proc.send_signal(sig)
        out, err = proc.communicate(timeout=60)
    finally:
        proc.kill()

    assert proc.returncode == 1
    assert out == ""
    assert "restored from the original bytes (verified)" in err
    assert dst.read_bytes() == before
