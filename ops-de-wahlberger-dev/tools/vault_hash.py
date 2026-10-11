"""Compare Vault values between two vault files by SHA-256, never printing values.

Plaintext only ever lives in this process' memory (``ansible-vault view`` stdout is
captured, never echoed). Output per key is ``match`` or ``MISMATCH`` (SH-AC-17).
"""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
from collections.abc import Callable
from pathlib import Path
from typing import Optional

MATCH = "match"
MISMATCH = "MISMATCH"
_TOP_LEVEL = re.compile(r"^([A-Za-z_][A-Za-z0-9_.-]*):(?:[ \t]+(.*))?$")


class VaultError(Exception):
    """`ansible-vault view` failed or its output cannot be parsed (exit code 2)."""


def parse_top_level(text: str) -> dict[str, str]:
    """Top-level scalars of a flat vault file (quoted, plain and ``|`` / ``>`` blocks).

    PyYAML is used when importable; the fallback understands only the flat
    ``key: value`` shape of ``vault.yml.example``.
    """
    try:
        import yaml
    except ImportError:
        return _parse_flat(text)
    try:
        data = yaml.safe_load(text) or {}
    except yaml.YAMLError:
        # The parser's message quotes the offending line, which can be a secret.
        raise VaultError("decrypted vault is not valid YAML (details withheld)") from None
    if not isinstance(data, dict):
        raise VaultError("vault content is not a mapping")
    return {str(k): str(v) for k, v in data.items() if v is not None}


def _parse_flat(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        m = _TOP_LEVEL.match(lines[i])
        i += 1
        if not m:
            continue
        key, raw = m.group(1), (m.group(2) or "").strip()
        if raw[:1] in ("|", ">"):
            block: list[str] = []
            while i < len(lines) and (not lines[i].strip() or lines[i][:1] in " \t"):
                block.append(lines[i].strip())
                i += 1
            joiner = "\n" if raw[0] == "|" else " "
            out[key] = joiner.join(block).strip("\n")
        elif raw.startswith('"'):
            try:
                out[key] = json.loads(raw[: raw.rindex('"') + 1])
            except (ValueError, json.JSONDecodeError) as err:
                raise VaultError(f"cannot parse double-quoted value for key {key!r}") from err
        elif raw.startswith("'"):
            out[key] = _single_quoted(raw, key)
        else:
            out[key] = re.sub(r"\s+#.*$", "", raw)
    return out


def _single_quoted(raw: str, key: str) -> str:
    """Value of a YAML single-quoted scalar (``''`` is an escaped quote); trailing comment ok."""
    chars: list[str] = []
    i = 1
    while i < len(raw):
        if raw[i] == "'":
            if raw[i + 1 : i + 2] == "'":
                chars.append("'")
                i += 2
                continue
            return "".join(chars)
        chars.append(raw[i])
        i += 1
    raise VaultError(f"unterminated single-quoted value for key {key!r}")


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def compare_values(
    keys: list[str], left: dict[str, str], right: dict[str, str]
) -> list[tuple[str, str, str]]:
    """Return ``(key, verdict, note)``; a key missing on either side is a MISMATCH."""
    results: list[tuple[str, str, str]] = []
    for key in keys:
        missing = [side for side, data in (("pi", left), ("vm", right)) if key not in data]
        if missing:
            results.append((key, MISMATCH, "missing in " + ",".join(missing)))
        elif _digest(left[key]) == _digest(right[key]):
            results.append((key, MATCH, ""))
        else:
            results.append((key, MISMATCH, ""))
    return results


Viewer = Callable[[Path, Optional[Path]], str]


def view_with_ansible_vault(vault: Path, password_file: Path | None) -> str:
    """Decrypt via `ansible-vault view` from the playbook dir (its ansible.cfg applies)."""
    # <playbook>/inventories/production/group_vars/all/vault.yml -> parents[4] is <playbook>
    cwd = vault.parents[4] if len(vault.parents) > 4 else vault.parent
    cmd = ["ansible-vault", "view", str(vault.resolve())]
    if password_file is not None:
        cmd += ["--vault-password-file", str(password_file.resolve())]
    try:
        proc = subprocess.run(  # noqa: S603  (list args, no shell)
            cmd, cwd=cwd, capture_output=True, text=True, check=False, timeout=120
        )
    except (OSError, subprocess.TimeoutExpired) as err:
        raise VaultError(f"cannot run ansible-vault on {vault}: {err}") from err
    if proc.returncode != 0:
        # stderr of ansible-vault names the problem (wrong password, not a vault) but never contents
        raise VaultError(f"ansible-vault view {vault} failed (exit {proc.returncode})")
    return proc.stdout


def run(
    keys: list[str],
    pi_vault: Path,
    vm_vault: Path,
    pi_pass: Path | None = None,
    vm_pass: Path | None = None,
    viewer: Viewer = view_with_ansible_vault,
) -> list[tuple[str, str, str]]:
    left = parse_top_level(viewer(pi_vault, pi_pass))
    right = parse_top_level(viewer(vm_vault, vm_pass))
    return compare_values(keys, left, right)
