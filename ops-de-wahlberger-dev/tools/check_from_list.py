"""Check the new automation key line across nas, cloud and the VM playbook (SH-AC-23, SH-FR-126).

The line in ``ssh_authorized_keys_list`` carrying the comment
``semaphore-automation@ops.de.wahlberger.dev`` must be the same string in all three
vars files and its ``from=`` option must list exactly <vm-public-ip>, <vm-zt-ip>,
<sem-subnet> plus optional extra addresses (SH-FR-191). Only public key material is read.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

KEY_COMMENT = "semaphore-automation@ops.de.wahlberger.dev"
VARS_REL = Path("inventories/production/group_vars/all/vars.yml")
PLAYBOOK_DIRS = ("nas-de-int-wahlberger-dev", "cloud-wahlberger-dev", "ops-de-wahlberger-dev")
LIST_VAR = "ssh_authorized_keys_list"
_ENTRY = re.compile(r"^\s+-\s+(.*?)\s*$")
_FROM = re.compile(r'^from="([^"]*)"\s+(\S.*)$')


class CheckError(Exception):
    """Input files are missing or unreadable (exit code 2)."""


@dataclass
class Result:
    problems: list[str] = field(default_factory=list)
    lines: dict[str, str] = field(default_factory=dict)

    @property
    def ok(self) -> bool:
        return not self.problems


def _unquote(raw: str) -> str:
    if len(raw) >= 2 and raw[0] == raw[-1] == '"':
        return re.sub(r'\\(["\\])', r"\1", raw[1:-1])
    if len(raw) >= 2 and raw[0] == raw[-1] == "'":
        return raw[1:-1].replace("''", "'")
    return raw


def list_entries(text: str) -> list[str]:
    """Entries of the top-level ``ssh_authorized_keys_list`` block, comments skipped."""
    raw: list[str] = []
    inside = False
    for line in text.splitlines():
        if re.match(rf"^{LIST_VAR}:\s*$", line):
            inside = True
            continue
        if inside and re.match(r"^\S", line) and not line.startswith("#"):
            break
        if inside and (m := _ENTRY.match(line)):
            raw.append(m.group(1))
        elif inside and raw and re.match(r"^\s{4,}\S", line):
            # A quoted scalar folded over several lines: YAML joins them with one space.
            raw[-1] = raw[-1] + " " + line.strip()
    return [_unquote(r) for r in raw]


def read_var(text: str, name: str) -> str | None:
    m = re.search(rf'^{name}:\s*["\']?([^"\'#\s]+)', text, re.MULTILINE)
    return m.group(1) if m else None


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as err:
        raise CheckError(f"cannot read {path}: {err}") from err


def check(
    repo: Path,
    vm_public_ip: str,
    vm_zt_ip: str | None = None,
    sem_subnet: str | None = None,
    extras: tuple[str, ...] = (),
) -> Result:
    result = Result()
    texts = {d: _read(repo / d / VARS_REL) for d in PLAYBOOK_DIRS}
    vm_text = texts["ops-de-wahlberger-dev"]
    vm_zt_ip = vm_zt_ip or read_var(vm_text, "vm_zt_ip")
    sem_subnet = sem_subnet or read_var(vm_text, "semaphore_network_subnet")
    if not vm_zt_ip or not sem_subnet:
        raise CheckError("vm_zt_ip / semaphore_network_subnet are empty; pass them explicitly")
    expected = sorted({vm_public_ip, vm_zt_ip, sem_subnet, *extras})
    for d, text in texts.items():
        found = [e for e in list_entries(text) if e.rstrip().endswith(KEY_COMMENT)]
        if len(found) != 1:
            result.problems.append(f"{d}: expected exactly one new-key line, found {len(found)}")
            continue
        result.lines[d] = found[0]
    if len(set(result.lines.values())) > 1:
        result.problems.append("the new key line differs between: " + ", ".join(result.lines))
    for d, line in result.lines.items():
        m = _FROM.match(line)
        if not m:
            result.problems.append(f'{d}: line does not start with from="..."')
            continue
        listed = [a.strip() for a in m.group(1).split(",")]
        if sorted(listed) != expected:
            result.problems.append(f"{d}: from= lists {sorted(listed)}, expected {expected}")
        if not m.group(2).startswith("ssh-ed25519 "):
            result.problems.append(f"{d}: key type is not ssh-ed25519")
    return result
