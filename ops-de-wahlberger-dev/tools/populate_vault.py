"""Build the VM's real ``vault.yml`` from a manifest (SH-FR-43/44/46/146..148/201, SH-BR-09).

Operator-run (Erik, 1Password unlocked). Per VM vault key the manifest says where the
value comes from: copied from another playbook's Vault (``pi``, ``cloud``, ``nas``) or
generated locally (``generate:alnum32``). Plaintext lives only in this process' memory
and in pipes: ``ansible-vault`` gets the plaintext on stdin and the password through a
pipe, never through a file, argv or the environment. Nothing here prints a value.

Source Vaults are read with ``vault_hash.view_with_ansible_vault``, i.e. ``ansible-vault
view`` run from the SOURCE PLAYBOOK dir, so that playbook's own ansible.cfg and
``.vault_pass.sh`` apply (deliberate; this is what needs the 1Password unlock). The VM
Vault itself is handled in a scratch cwd with an empty ANSIBLE_CONFIG, so only the
password this module read through ``op`` is ever used for it.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import shutil
import string
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

from vault_hash import (
    MATCH,
    MISMATCH,
    VaultError,
    compare_values,
    parse_top_level,
    view_with_ansible_vault,
)

VAULT_REL = Path("inventories/production/group_vars/all/vault.yml")
SOURCE_DIRS = {
    "pi": "pi-de-int-wahlberger-dev",
    "cloud": "cloud-wahlberger-dev",
    "nas": "nas-de-int-wahlberger-dev",
}
ALNUM = string.ascii_letters + string.digits
GENERATORS = {"alnum32": 32}
VAULT_HEADER = b"$ANSIBLE_VAULT;"
_KEY = re.compile(r"^vault_[a-z0-9_]+$")
# The reference contains spaces, so it must be quoted (as in .vault_pass.sh).
_OP_REF = re.compile(r"""op\s+read\s+(?:"(op://[^"]+)"|'(op://[^']+)')""")
_MANIFEST_KEY_LINE = re.compile(r"^([A-Za-z_][A-Za-z0-9_.-]*):")


class PopulateError(Exception):
    """Input, source or tooling problem (exit code 2). Messages never contain values."""


class Refused(PopulateError):
    """The target already holds a vault and no flag allows replacing it (exit code 3)."""


@dataclass(frozen=True)
class Entry:
    key: str
    kind: str  # "copy" or "generate"
    source: str = ""  # pi | cloud | nas
    source_key: str = ""
    generator: str = ""


def sha8(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:8]


# ------------------------------------------------------------------- manifest
def parse_manifest(text: str) -> list[Entry]:
    """``vault_key: pi:source_key`` / ``vault_key: generate:alnum32`` (one flat mapping)."""
    seen: set[str] = set()
    for line in text.splitlines():
        m = _MANIFEST_KEY_LINE.match(line)
        if m:
            if m.group(1) in seen:
                raise PopulateError(f"manifest: duplicate key {m.group(1)}")
            seen.add(m.group(1))
    try:
        mapping = parse_top_level(text)
    except VaultError as err:  # parse_top_level words its errors without file content
        raise PopulateError(f"manifest: {err}") from None
    if not mapping:
        raise PopulateError("manifest: no entries")
    entries: list[Entry] = []
    for key, spec in mapping.items():
        if not _KEY.match(key):
            raise PopulateError(f"manifest: {key!r} is not a vault_* key")
        kind, _, rest = spec.strip().partition(":")
        if kind == "generate":
            if rest not in GENERATORS:
                raise PopulateError(f"manifest: {key}: unknown generator {rest!r}")
            entries.append(Entry(key, "generate", generator=rest))
        elif kind in SOURCE_DIRS:
            if not _KEY.match(rest):
                raise PopulateError(f"manifest: {key}: bad source key {rest!r}")
            entries.append(Entry(key, "copy", source=kind, source_key=rest))
        else:
            raise PopulateError(f"manifest: {key}: source must be pi|cloud|nas|generate")
    return entries


# ------------------------------------------------------------- password (op)
def op_reference(ops_dir: Path) -> str:
    """The exact ``op://`` reference of ``<ops_dir>/.vault_pass.sh`` (never hard-coded here)."""
    script = ops_dir / ".vault_pass.sh"
    try:
        text = script.read_text(encoding="utf-8")
    except OSError as err:
        raise PopulateError(f"cannot read {script}: {err.strerror}") from None
    found = [double or single for double, single in _OP_REF.findall(text)]
    if len(found) != 1:
        raise PopulateError(
            f"{script} must contain exactly one quoted 'op read op://...' reference"
        )
    return found[0]


def read_password(reference: str) -> str:
    """Run ``op read <reference> --no-newline`` (stdout captured, never echoed)."""
    try:
        proc = subprocess.run(  # noqa: S603  (list args, no shell)
            ["op", "read", reference, "--no-newline"],  # noqa: S607
            stdout=subprocess.PIPE,
            text=True,
            check=False,
            timeout=300,
        )
    except (OSError, subprocess.TimeoutExpired) as err:
        raise PopulateError(f"cannot run `op read`: {type(err).__name__}") from None
    if proc.returncode != 0 or not proc.stdout:
        raise PopulateError(f"`op read` failed or returned nothing (exit {proc.returncode})")
    return proc.stdout


# ------------------------------------------ ansible-vault on the VM vault only
def _ansible_vault() -> str:
    found = shutil.which("ansible-vault")
    if not found:
        raise PopulateError("ansible-vault not found on PATH")
    return found


def _run_vault(
    args: list[str], password: str, stdin: bytes | None = None
) -> subprocess.CompletedProcess:
    """ansible-vault in a scratch cwd, empty ANSIBLE_CONFIG, password through a pipe."""
    with tempfile.TemporaryDirectory(prefix="populate-vault-") as scratch:
        cfg = Path(scratch) / "empty-ansible.cfg"
        cfg.write_text("")
        env = {
            k: v
            for k, v in os.environ.items()
            if k not in ("ANSIBLE_VAULT_PASSWORD_FILE", "ANSIBLE_VAULT_IDENTITY_LIST")
        }
        env["ANSIBLE_CONFIG"] = str(cfg)
        read_fd, write_fd = os.pipe()
        try:
            os.write(write_fd, password.encode("utf-8"))
            os.close(write_fd)
            write_fd = -1
            return subprocess.run(  # noqa: S603
                [
                    _ansible_vault(),
                    args[0],
                    "--vault-password-file",
                    f"/dev/fd/{read_fd}",
                    *args[1:],
                ],
                input=stdin,
                capture_output=True,
                check=False,
                timeout=120,
                env=env,
                cwd=scratch,
                pass_fds=(read_fd,),
            )
        except (OSError, subprocess.TimeoutExpired) as err:
            raise PopulateError(f"cannot run ansible-vault: {type(err).__name__}") from None
        finally:
            os.close(read_fd)
            if write_fd != -1:
                os.close(write_fd)


def view_vm_vault(path: Path, password: str) -> dict[str, str]:
    proc = _run_vault(["view", str(path.resolve())], password)
    if proc.returncode != 0:
        raise VaultError(f"ansible-vault view {path} failed (exit {proc.returncode})")
    return parse_top_level(proc.stdout.decode("utf-8"))


def encrypt_to(plaintext: str, out: Path, password: str) -> None:
    proc = _run_vault(
        ["encrypt", "--output", str(out), "-"], password, stdin=plaintext.encode("utf-8")
    )
    if proc.returncode != 0:
        raise PopulateError(f"ansible-vault encrypt failed (exit {proc.returncode})")


# ----------------------------------------------------------------- the work
def generate(kind: str) -> str:
    return "".join(secrets.choice(ALNUM) for _ in range(GENERATORS[kind]))


def valid_generated(kind: str, value: str) -> bool:
    return len(value) == GENERATORS[kind] and all(c in ALNUM for c in value)


def render_plaintext(entries: list[Entry], values: dict[str, str]) -> str:
    """Flat YAML; each value a JSON string (a valid YAML double-quoted scalar)."""
    lines = ["---"] + [f"{e.key}: {json.dumps(values[e.key], ensure_ascii=False)}" for e in entries]
    return "\n".join(lines) + "\n"


Viewer = Callable[[Path, Optional[Path]], str]


def read_sources(
    entries: list[Entry], repo_root: Path, viewer: Viewer = view_with_ansible_vault
) -> dict[str, str]:
    """Value per copied key; every missing or empty source key is reported at once."""
    by_source: dict[str, dict[str, str]] = {}
    for source in sorted({e.source for e in entries if e.kind == "copy"}):
        vault = repo_root / SOURCE_DIRS[source] / VAULT_REL
        if not vault.is_file():
            raise PopulateError(f"source vault missing: {vault}")
        try:
            by_source[source] = parse_top_level(viewer(vault, None))
        except VaultError as err:
            raise PopulateError(f"cannot read the {source} vault: {err}") from None
    problems = []
    values: dict[str, str] = {}
    for e in entries:
        if e.kind != "copy":
            continue
        got = by_source[e.source].get(e.source_key)
        if got is None:
            problems.append(f"{e.source}:{e.source_key} (for {e.key}) is missing")
        elif got == "":
            problems.append(f"{e.source}:{e.source_key} (for {e.key}) is empty")
        else:
            values[e.key] = got
    if problems:
        raise PopulateError("refusing, source keys not usable:\n  " + "\n  ".join(problems))
    return values


@dataclass
class Options:
    manifest: Path
    ops_dir: Path
    repo_root: Path
    force: bool = False
    replace_placeholder: bool = False
    regenerate_secrets: bool = False
    show_hash: bool = False


def populate(opts: Options, out: Callable[[str], None] = print) -> int:
    """Returns 0 (all verified), 1 (a MISMATCH / format failure). Raises PopulateError/Refused."""
    entries = parse_manifest(opts.manifest.read_text(encoding="utf-8"))
    target = opts.ops_dir / VAULT_REL
    password = read_password(op_reference(opts.ops_dir))

    existing: dict[str, str] = {}
    if target.exists():
        head = target.read_bytes()[: len(VAULT_HEADER)]
        if head != VAULT_HEADER:
            if not opts.force:
                raise Refused(f"{target} exists and is not an Ansible Vault file; use --force")
        else:
            try:
                existing = view_vm_vault(target, password)
            except VaultError:
                if not (opts.force or opts.replace_placeholder):
                    raise Refused(
                        f"{target} is encrypted with another password (the throwaway "
                        "placeholder?); rerun with --replace-placeholder to replace it"
                    ) from None
            else:
                if not opts.force:
                    raise Refused(f"{target} already holds a real vault; use --force to rebuild it")

    copied = read_sources(entries, opts.repo_root)  # before any write; fails on any gap
    values = dict(copied)
    states: dict[str, str] = {e.key: "copied" for e in entries if e.kind == "copy"}
    for e in entries:
        if e.kind != "generate":
            continue
        keep = existing.get(e.key)
        if keep is not None and valid_generated(e.generator, keep) and not opts.regenerate_secrets:
            values[e.key], states[e.key] = keep, "kept"
        else:
            values[e.key], states[e.key] = generate(e.generator), "generated"
    for e in entries:
        out(_line(e, values[e.key], states[e.key], opts.show_hash))

    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=".vault.yml.", dir=target.parent)
    os.close(fd)
    tmp = Path(tmp_name)
    try:
        encrypt_to(render_plaintext(entries, values), tmp, password)
        tmp.chmod(0o600)
        tmp.replace(target)
    finally:
        tmp.unlink(missing_ok=True)
    target.chmod(0o600)
    out(f"wrote {target} (mode 0600)")
    return verify(entries, opts, password, out)


def _line(e: Entry, value: str, state: str, show_hash: bool) -> str:
    origin = f" from {e.source}:{e.source_key}" if e.kind == "copy" else f" ({e.generator})"
    suffix = f"  sha256:{sha8(value)}" if show_hash else ""
    return f"{e.key}: {state}{origin}{suffix}"


def verify(entries: list[Entry], opts: Options, password: str, out: Callable[[str], None]) -> int:
    """Re-read the new vault and the sources; print match/MISMATCH per copied key."""
    target = opts.ops_dir / VAULT_REL
    out("verify (new vault re-read, sources re-read):")
    new = view_vm_vault(target, password)
    bad = 0
    extra = sorted(set(new) - {e.key for e in entries})
    if extra:
        out("unexpected keys in the new vault: " + ", ".join(extra))
        bad += 1
    copy_entries = [e for e in entries if e.kind == "copy"]
    if copy_entries:
        fresh = read_sources(entries, opts.repo_root)
        for e, (_, verdict, note) in zip(
            copy_entries,
            compare_values(
                [e.key for e in copy_entries],
                {e.key: fresh[e.key] for e in copy_entries},
                new,
            ),
        ):
            out(f"{e.key}: {verdict}" + (f" ({note})" if note else ""))
            bad += verdict != MATCH
    for e in entries:
        if e.kind != "generate":
            continue
        ok = e.key in new and valid_generated(e.generator, new[e.key])
        out(f"{e.key}: {'ok' if ok else 'BAD-FORMAT'} ({e.generator})")
        bad += not ok
    out("all verified" if not bad else f"{MISMATCH}: {bad} check(s) failed")
    return 1 if bad else 0
