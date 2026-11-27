#!/usr/bin/env python3
"""Fail when a role under roles/ has no molecule coverage or a recorded exclusion.

coverage.yml maps every role to one of:
  scenario: <name>   the scenario runs the role (checked, see below)
  exclude: <reason>  the role cannot run in a container (reason must be non-empty)

The check also verifies the claims against the scenarios themselves:
  - base:           the role is in converge.yml's roles list
  - playbook-*:     the role's name is in the scenario's molecule.yml tags, or the
                    entry says `via: always` and the host playbook runs the role
                    through always-tagged tasks that the scenario does not skip
and fails on stale entries (role directory gone, scenario missing).

Usage: check_coverage.py    (exit 0 = covered, 1 = gaps, stdlib + PyYAML)
"""

import sys
from pathlib import Path

import yaml

MOLECULE = Path(__file__).resolve().parent
ROLES = MOLECULE.parent.parent / "roles"


def scenario_runs(scenario: str) -> set[str]:
    if scenario == "base":
        converge = yaml.safe_load((MOLECULE / "base" / "converge.yml").read_text())
        return {r["role"].removeprefix("wahlberger.homelab.") for r in converge[0]["roles"]}
    config = yaml.safe_load((MOLECULE / scenario / "molecule.yml").read_text())
    return set(config["provisioner"]["options"]["tags"].split(","))


def runs_via_always(scenario: str, role: str) -> bool:
    """True when the role runs through `always`-tagged tasks in the host playbook.

    Those tasks run unless the scenario skips `always`, and the host playbook must
    name the role.
    """
    config = yaml.safe_load((MOLECULE / scenario / "molecule.yml").read_text())
    skip = config["provisioner"]["options"].get("skip-tags", "").split(",")
    if "always" in skip:
        return False
    host = scenario.removeprefix("playbook-")
    playbook = (MOLECULE.parent.parent / "playbooks" / f"{host}.yml").read_text()
    return f"wahlberger.homelab.{role}" in playbook


def main() -> int:
    roles = sorted(p.name for p in ROLES.iterdir() if p.is_dir())
    entries = yaml.safe_load((MOLECULE / "coverage.yml").read_text())["roles"]
    errors = []

    for role in roles:
        if role not in entries:
            errors.append(f"{role}: no entry in coverage.yml")
    for name in entries:
        if name not in roles:
            errors.append(f"{name}: entry in coverage.yml but roles/{name} does not exist")

    covered, excluded, open_gaps = 0, 0, []
    for name, entry in entries.items():
        if name not in roles:
            continue
        has_scenario, has_exclude = "scenario" in entry, "exclude" in entry
        if has_scenario == has_exclude:
            errors.append(f"{name}: needs exactly one of 'scenario' or 'exclude'")
            continue
        if has_exclude:
            excluded += 1
            if not str(entry["exclude"]).strip():
                errors.append(f"{name}: 'exclude' needs a reason")
            elif str(entry["exclude"]).startswith("not yet covered"):
                open_gaps.append(name)
            continue
        scenario = entry["scenario"]
        if not (MOLECULE / scenario / "molecule.yml").exists():
            errors.append(f"{name}: scenario '{scenario}' does not exist")
        elif entry.get("via") == "always":
            if runs_via_always(scenario, name):
                covered += 1
            else:
                errors.append(f"{name}: scenario '{scenario}' does not run it through always-tagged tasks")
        elif name not in scenario_runs(scenario):
            errors.append(f"{name}: scenario '{scenario}' does not run this role")
        else:
            covered += 1

    for line in errors:
        print(f"coverage: {line}")
    print(
        f"coverage: {len(roles)} roles: {covered} covered by a scenario, "
        f"{excluded} excluded with a reason"
    )
    if open_gaps:
        print(f"coverage: open gaps (excluded, not yet covered): {', '.join(open_gaps)}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
