"""Copy values between Ansible Vault files under different key names, never printing a value.

The destination plaintext is kept byte-for-byte: a new key is APPENDED as ``key: "value"``
(JSON quoting, a valid YAML double-quoted scalar); with ``force`` only the one existing
line of that key is replaced. Plaintext and passwords live in memory and in pipes only.
Per key the only output is ``<dst-key>: copied, match|MISMATCH|already present, equal``.

Safety net around the one real write: the original encrypted bytes go to ``<vault>.bak``
(0600) first; any failure from the write through the verification restores them (verified);
the ``.bak`` is deleted only after a complete, successful verification. PyYAML is required
(duplicate keys, document markers and the "all other keys unchanged" check depend on it).
"""

from __future__ import annotations

import functools
import json
import os
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional, TextIO

from vault_hash import MATCH, MISMATCH, VaultError, _digest

KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
ALREADY_EQUAL = "already present, equal"
COPIED = "copied"
VAULT_HEADER = b"$ANSIBLE_VAULT;"
EXIT_RESTORE_FAILED = 3
MAX_PASS_FILE_BYTES = 4096  # written to a pipe before the child starts: must fit the pipe buffer
NOT_FOUND_HINT = "ansible-vault not found; put $HOME/.pyenv/versions/ansible-bind9-venv/bin on PATH"
VENV_BIN_REL = Path(".pyenv/versions/ansible-bind9-venv/bin")
# Inherited settings that would add a second secret or another config to the child.
STRIPPED_ENV = (
    "ANSIBLE_CONFIG",
    "ANSIBLE_VAULT_PASSWORD_FILE",
    "ANSIBLE_VAULT_IDENTITY",
    "ANSIBLE_VAULT_IDENTITY_LIST",
    "ANSIBLE_VAULT_ID_MATCH",
    "ANSIBLE_VAULT_ENCRYPT_SALT",
)
_MARKER_RE = re.compile(r"^(---|\.\.\.)(?:\s|$)")


class CopyError(Exception):
    """A usage or data problem; nothing was written (exit code 2)."""


class MissingDependency(CopyError):
    """PyYAML is not importable; the safety checks cannot run (exit code 2)."""


class Refused(CopyError):
    """The destination key exists with a different value and --force was not given."""


@dataclass(frozen=True)
class CopySpec:
    src_vault: Path
    src_key: str
    dst_key: str


def parse_copy_spec(spec: str) -> CopySpec:
    """``<src-vault.yml>:<src-key>=<dst-key>``; the path is split on its last colon."""
    left, eq, dst_key = spec.rpartition("=")
    path, colon, src_key = left.rpartition(":")
    if not (eq and colon and path and KEY_RE.match(src_key) and KEY_RE.match(dst_key)):
        raise CopyError(f"expected <vault.yml>:<src-key>=<dst-key>, got {spec!r}")
    return CopySpec(Path(path), src_key, dst_key)


# ------------------------------------------------------------------- YAML (strict)
class DuplicateKey(Exception):
    """A mapping repeats a key (PyYAML would silently keep the last one)."""


@functools.lru_cache(maxsize=1)
def _loader_cls() -> Any:
    try:
        import yaml
    except ImportError:
        raise MissingDependency(
            "PyYAML is required (duplicate keys, document markers and unchanged-other-keys "
            "checks need it); run with the ansible venv python, e.g. "
            "$HOME/.pyenv/versions/ansible-bind9-venv/bin/python"
        ) from None

    class Loader(yaml.SafeLoader):
        def construct_mapping(self, node: Any, deep: bool = False) -> Any:
            if isinstance(node, yaml.MappingNode):
                self.flatten_mapping(node)
                seen: list[Any] = []
                for key_node, _ in node.value:
                    key = self.construct_object(key_node, deep=True)
                    try:
                        dup = key in seen
                    except TypeError:
                        dup = False
                    if dup:
                        raise DuplicateKey(str(key))
                    seen.append(key)
            return super().construct_mapping(node, deep)

    # inline `!vault |` values are opaque ciphertext: keep them comparable, never decrypt
    Loader.add_constructor("!vault", lambda loader, node: "!vault " + loader.construct_scalar(node))
    return Loader


def require_yaml() -> None:
    _loader_cls()


def parse_raw(text: str) -> dict[Any, Any]:
    """Top-level mapping with native values; one document, no duplicate key anywhere."""
    loader = _loader_cls()
    import yaml

    try:
        docs = list(yaml.load_all(text, Loader=loader))
    except DuplicateKey as exc:
        raise CopyError(
            f"key {exc} appears more than once in the vault (nothing written)"
        ) from None
    except yaml.YAMLError:
        # the parser's message quotes the offending line, which can be a secret
        raise CopyError("vault content is not valid YAML (details withheld)") from None
    if len(docs) > 1:
        raise CopyError("vault content holds more than one YAML document (nothing written)")
    data = docs[0] if docs else None
    if data is None:
        return {}
    if not isinstance(data, dict):
        raise CopyError("vault content is not a mapping")
    return data


def parse_strict(text: str) -> dict[str, str]:
    """Like ``vault_hash.parse_top_level`` (str values, None dropped) but PyYAML-only."""
    return {str(k): str(v) for k, v in parse_raw(text).items() if v is not None}


def check_markers(text: str) -> None:
    """Only one leading ``---`` is allowed (a later ``---`` or any ``...`` ends the document)."""
    seen_content = False
    seen_start = False
    for line in text.split("\n"):
        bare = line.rstrip("\r")
        if _MARKER_RE.match(bare):
            if bare.strip() != "---" or seen_content or seen_start:
                raise CopyError(
                    "the vault holds a YAML document marker (---/...) other than one "
                    "leading '---'; refusing, nothing written"
                )
            seen_start = True
        elif bare.strip() and not bare.lstrip().startswith("#"):
            seen_content = True


# ---------------------------------------------------------------- text editing
def _is_key_line(line: str, key: str) -> bool:
    return line.startswith(key + ":") and (
        len(line) == len(key) + 1 or line[len(key) + 1] in " \t\r\n"
    )


def _lines(text: str) -> list[str]:
    # not str.splitlines(): it also splits on \x0b, \x0c, \x85, U+2028 ... inside values
    return re.findall(r"[^\n]*\n|[^\n]+", text)


def format_line(key: str, value: str, newline: str = "\n") -> str:
    return f"{key}: {json.dumps(value, ensure_ascii=False)}{newline}"


def set_key(text: str, key: str, value: str, *, must_exist: bool = False) -> str:
    """Append ``key`` or, if present, replace exactly its line (and its block continuation).

    ``must_exist``: the caller knows (from the YAML parse) that the key is there, so failing to
    find its plain ``key:`` line (quoted key, ``key : v``) is an error, not a reason to append.
    """
    newline = "\r\n" if "\r\n" in text else "\n"
    new = format_line(key, value, newline)
    lines = _lines(text)
    hits = [i for i, ln in enumerate(lines) if _is_key_line(ln, key)]
    if len(hits) > 1:
        raise CopyError(f"{key} appears more than once in the destination vault")
    if not hits:
        if must_exist:
            raise CopyError(f"{key} exists but not as a plain `{key}: value` line; edit by hand")
        return text + ("" if not text or text.endswith("\n") else newline) + new
    start = hits[0]
    end = start + 1
    while end < len(lines):  # continuation: indented lines, blank ones only if more follow
        probe = end
        while probe < len(lines) and not lines[probe].strip():
            probe += 1
        if probe < len(lines) and lines[probe][:1] in (" ", "\t"):
            end = probe + 1
        else:
            break
    return "".join(lines[:start]) + new + "".join(lines[end:])


# ----------------------------------------------------------- ansible-vault I/O
Decryptor = Callable[[Path, Optional[Path]], str]
Encryptor = Callable[[str, Path, Optional[Path]], bytes]
Viewer = Callable[[Path, Optional[Path]], str]
Writer = Callable[[Path, bytes], None]


def playbook_dir(vault: Path) -> Path:
    """<playbook>/inventories/production/group_vars/all/vault.yml -> <playbook>."""
    return vault.parents[4] if len(vault.parents) > 4 else vault.parent


def check_pass_file(path: Path | None) -> None:
    """A plain password file: ansible would EXECUTE an executable one (its source != password)."""
    if path is None:
        return
    if not path.is_file():
        raise CopyError(f"password file missing: {path}")
    if path.stat().st_size > MAX_PASS_FILE_BYTES:
        raise CopyError(
            f"password file {path} is larger than {MAX_PASS_FILE_BYTES} bytes; "
            "that is not a password file. Refusing"
        )
    if os.access(path, os.X_OK):
        raise CopyError(
            f"password file {path} is executable; ansible would run it as a script. Refusing "
            "(use a non-executable file holding the password, or leave it unset)"
        )


def _child_env(config: Path) -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if k not in STRIPPED_ENV}
    env["ANSIBLE_CONFIG"] = str(config)
    return env


def vault_binaries() -> list[str]:
    """Absolute ansible-vault candidates: PATH, the running python's bin dir, the ansible venv.

    A pyenv shim can win the PATH lookup and still answer 127 (version without the tool), so
    the caller tries the next candidate on 127.
    """
    found = [
        shutil.which("ansible-vault"),
        str(Path(sys.executable).parent / "ansible-vault"),
        str(Path.home() / VENV_BIN_REL / "ansible-vault"),
    ]
    out: list[str] = []
    for cand in found:
        if cand and cand not in out and os.access(cand, os.X_OK) and Path(cand).is_file():
            out.append(cand)
    return out


def _run_vault(vault: Path, args: list[str], pass_file: Path | None, stdin: bytes | None) -> bytes:
    """ansible-vault with exactly ONE vault-secret source.

    With a password file: an empty ANSIBLE_CONFIG (the playbook's ansible.cfg would add its own
    ``vault_password_file`` for the same vault id) and the file handed over through a pipe.
    Without: the playbook's own ansible.cfg, named explicitly.
    """
    tail = [args[0], *args[1:]]
    check_pass_file(pass_file)
    cfg = (
        playbook_dir(vault) / "ansible.cfg"
    ).resolve()  # absolute: the child runs in cwd=playbook
    if pass_file is None and not cfg.is_file():
        raise VaultError(f"{cfg} is missing (it supplies the vault password); use a password file")
    read_fd = write_fd = -1
    proc: subprocess.CompletedProcess[bytes] | None = None
    with tempfile.TemporaryDirectory(prefix="vault-copy-") as tmp:  # 0700, removal errors raise
        if pass_file is not None:
            cfg = Path(tmp) / "empty.cfg"
            cfg.write_bytes(b"")
        try:
            if pass_file is not None:
                read_fd, write_fd = os.pipe()
                os.write(write_fd, pass_file.read_bytes())
                os.close(write_fd)
                write_fd = -1
                tail += ["--vault-password-file", f"/dev/fd/{read_fd}"]
            for binary in vault_binaries():
                try:
                    proc = subprocess.run(  # noqa: S603  (absolute path, list args, no shell)
                        [binary, *tail],
                        input=stdin,
                        stdin=None if stdin is not None else subprocess.DEVNULL,
                        capture_output=True,
                        check=False,
                        timeout=120,
                        cwd=playbook_dir(vault).resolve(),
                        env=_child_env(cfg),  # keeps the caller's PATH (password scripts, `op`)
                        pass_fds=(read_fd,) if read_fd != -1 else (),
                    )
                except FileNotFoundError:
                    continue
                if proc.returncode != 127:
                    break
                proc = None
        except (OSError, subprocess.TimeoutExpired) as err:
            raise VaultError(f"cannot run ansible-vault on {vault}: {type(err).__name__}") from None
        finally:
            for fd in (read_fd, write_fd):
                if fd != -1:
                    os.close(fd)
    if proc is None:
        raise VaultError(NOT_FOUND_HINT)
    if proc.returncode != 0:
        # ansible-vault's stderr names the problem but is not forwarded (may quote content)
        raise VaultError(f"ansible-vault {args[0]} {vault} failed (exit {proc.returncode})")
    return proc.stdout


def decrypt_exact(vault: Path, pass_file: Path | None) -> str:
    """Plaintext byte-for-byte (``view`` would append a newline)."""
    out = _run_vault(vault, ["decrypt", "--output", "-", str(vault.resolve())], pass_file, None)
    try:
        return out.decode("utf-8")
    except UnicodeDecodeError:
        raise VaultError(f"{vault} is not valid UTF-8 text") from None


def encrypt_text(plaintext: str, vault: Path, pass_file: Path | None) -> bytes:
    return _run_vault(vault, ["encrypt", "--output", "-", "-"], pass_file, plaintext.encode())


def check_ciphertext(data: bytes) -> None:
    """Refuse to replace a vault with anything but a real, non-trivial Ansible Vault payload."""
    _, _, body = data.partition(b"\n")
    hex_body = b"".join(body.split())
    if (
        not data.startswith(VAULT_HEADER)
        or len(hex_body) < 64
        or any(c not in b"0123456789abcdefABCDEF" for c in hex_body)
    ):
        raise CopyError("encryption returned no valid Ansible Vault payload; nothing written")


def write_atomic(path: Path, data: bytes) -> None:
    """Temp file next to ``path`` (0600), fsync, original mode, rename, fsync the directory.

    A symlink is followed: the real file is replaced, the link stays a link.
    """
    path = path.resolve()
    mode = stat.S_IMODE(path.stat().st_mode)
    fd, tmp_name = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
            os.fchmod(handle.fileno(), mode)
        tmp.replace(path)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise
    dir_fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)


def backup_path(vault: Path) -> Path:
    real = vault.resolve()  # next to the real file, like the write
    return real.with_name(real.name + ".bak")


def make_backup(vault: Path, original: bytes) -> Path:
    """Original encrypted bytes to ``<vault>.bak`` (0600, exclusive, fsynced)."""
    bak = backup_path(vault)
    try:
        fd = os.open(bak, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        raise CopyError(
            f"{bak} already exists (maybe from an earlier failed run); compare it with the "
            "vault, then move or delete it. Nothing written"
        ) from None
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(original)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        bak.unlink(missing_ok=True)
        raise
    if bak.read_bytes() != original:
        bak.unlink(missing_ok=True)
        raise CopyError(f"backup {bak} did not verify; nothing written")
    return bak


# ---------------------------------------------------------------------- work
def read_sources(
    specs: list[CopySpec], src_pass: Path | None, viewer: Viewer | None = None
) -> dict[str, str]:
    """Value per dst key; every missing or empty source key is reported (names only)."""
    viewer = viewer or decrypt_exact
    cache: dict[Path, dict[str, str]] = {}
    values: dict[str, str] = {}
    problems: list[str] = []
    for spec in specs:
        if spec.src_vault not in cache:
            if not spec.src_vault.is_file():
                raise CopyError(f"source vault missing: {spec.src_vault}")
            cache[spec.src_vault] = parse_strict(viewer(spec.src_vault, src_pass))
        got = cache[spec.src_vault].get(spec.src_key)
        if got is None:
            problems.append(f"source key {spec.src_key} is missing")
        elif got == "":
            problems.append(f"source key {spec.src_key} is empty")
        else:
            values[spec.dst_key] = got
    if problems:
        raise CopyError("refusing, " + "; ".join(problems))
    return values


def _restore(dst: Path, original: bytes, restore: Writer) -> bool:
    """Put the original bytes back and verify them; never raises."""
    try:
        restore(dst, original)
        return dst.read_bytes() == original
    except BaseException:
        return False


def copy_keys(
    specs: list[CopySpec],
    dst: Path,
    *,
    src_pass: Path | None = None,
    dst_pass: Path | None = None,
    dry_run: bool = False,
    force: bool = False,
    out: TextIO | None = None,
    err: TextIO | None = None,
    viewer: Viewer | None = None,
    decrypt: Decryptor = decrypt_exact,
    encrypt: Encryptor = encrypt_text,
    write: Writer = write_atomic,
    restore: Writer = write_atomic,
) -> int:
    """Exit code 0 ok, 1 vault modified then restored (MISMATCH/failure), 2 nothing written,
    3 vault modified and the automatic restore failed (see the .bak)."""
    out = out or sys.stdout
    err = err or sys.stderr
    require_yaml()
    dst_keys = [s.dst_key for s in specs]
    if len(set(dst_keys)) != len(dst_keys):
        raise CopyError("a destination key is given twice")
    if not dst.is_file():
        raise CopyError(f"destination vault missing: {dst}")
    for pass_file in (src_pass, dst_pass):
        check_pass_file(pass_file)
    values = read_sources(specs, src_pass, viewer)
    original = dst.read_bytes()
    plain = decrypt(dst, dst_pass)
    check_markers(plain)
    existing = parse_strict(plain)

    todo: list[str] = []
    refused: list[str] = []
    for key in dst_keys:
        if key not in existing:
            todo.append(key)
        elif _digest(existing[key]) == _digest(values[key]):
            print(f"{key}: {ALREADY_EQUAL}", file=out)
        elif force:
            todo.append(key)
        else:
            refused.append(key)
    if refused:
        names = ", ".join(refused)
        raise Refused(f"{names} already present with a different value (use --force to replace)")

    new_plain = plain
    for key in todo:
        new_plain = set_key(new_plain, key, values[key], must_exist=key in existing)
    if todo:
        check_markers(new_plain)
        _check_parses(new_plain, {k: values[k] for k in todo})
        _check_others_unchanged(plain, new_plain, set(todo))
    if dry_run:
        for key in todo:
            verb = "would replace" if key in existing else "would copy"
            print(f"{key}: {verb} (dry run, nothing written)", file=out)
        return 0
    if not todo:
        return 0

    cipher = encrypt(new_plain, dst, dst_pass)
    check_ciphertext(cipher)
    bak = make_backup(dst, original)
    return _write_and_verify(
        dst,
        bak,
        original,
        cipher,
        new_plain,
        todo,
        values,
        dst_pass,
        out,
        err,
        decrypt=decrypt,
        write=write,
        restore=restore,
    )


def _write_and_verify(
    dst: Path,
    bak: Path,
    original: bytes,
    cipher: bytes,
    new_plain: str,
    todo: list[str],
    values: dict[str, str],
    dst_pass: Path | None,
    out: TextIO,
    err: TextIO,
    *,
    decrypt: Decryptor,
    write: Writer,
    restore: Writer,
) -> int:
    failure = "verification failed"
    mismatched: list[str] = []
    try:
        write(dst, cipher)
        reread = decrypt(dst, dst_pass)
        got = parse_strict(reread)
        mismatched = [k for k in todo if k not in got or _digest(got[k]) != _digest(values[k])]
        if not mismatched and reread == new_plain:
            ok = True
        else:
            ok = False
            failure = "the re-read vault does not equal what was intended"
    except BaseException as exc:
        ok = False
        failure = f"{type(exc).__name__} after the write started"
    if ok:
        try:
            bak.unlink()
        except OSError as exc:
            print(
                f"vault-copy-keys: WARNING: verified, but could not delete {bak} "
                f"({type(exc).__name__}); delete it yourself",
                file=err,
            )
        for key in todo:
            print(f"{key}: {COPIED}, {MATCH}", file=out)
        return 0
    for key in mismatched:
        print(f"{key}: {MISMATCH}", file=out)
    return _recover(dst, bak, original, failure, restore, err)


def _recover(
    dst: Path, bak: Path, original: bytes, failure: str, restore: Writer, err: TextIO
) -> int:
    try:
        unchanged = dst.read_bytes() == original
    except OSError:
        unchanged = False
    if unchanged:
        bak.unlink(missing_ok=True)
        print(f"vault-copy-keys: {failure}; the vault file is unchanged (verified)", file=err)
        return 2
    if _restore(dst, original, restore):
        print(
            f"vault-copy-keys: {failure}. The vault file was modified and has been restored "
            f"from the original bytes (verified); previous content restored. The backup {bak} "
            "is kept; delete it before the next run.",
            file=err,
        )
        return 1
    print(
        f"vault-copy-keys: CRITICAL: {failure}. The vault file {dst} was modified and could "
        f"NOT be restored automatically.\n  The original encrypted bytes are in {bak} (0600).\n"
        f"  Recover with:  cp {shlex.quote(str(bak))} {shlex.quote(str(dst))}\n"
        f"  or:            git checkout -- {shlex.quote(str(dst))}",
        file=err,
    )
    return EXIT_RESTORE_FAILED


def _check_parses(text: str, expected: dict[str, str]) -> None:
    """The edited plaintext must still parse and hold the new values (details withheld)."""
    parsed = parse_strict(text)
    for key, value in expected.items():
        if key not in parsed or _digest(parsed[key]) != _digest(value):
            raise CopyError(f"edited vault would not hold {key} correctly; nothing written")


def _check_others_unchanged(before: str, after: str, changed: set[str]) -> None:
    """Every key except the copied ones must parse to exactly the same value as before."""

    def rest(text: str) -> dict[Any, Any]:
        return {k: v for k, v in parse_raw(text).items() if k not in changed}

    if rest(before) != rest(after):
        raise CopyError("the edit would change other keys of the vault; nothing written")
