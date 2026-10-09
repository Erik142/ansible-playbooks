#!/usr/bin/env python3
"""Build RESULTS.md from $FIXTURE_VM_DIR/results.tsv (written by the scenario scripts).

The last record per scenario name wins. Static text (defect log, deviations) lives in
RESULTS-notes.md next to this script and is appended unchanged.
"""
import collections
import os
import pathlib
import sys

here = pathlib.Path(__file__).resolve().parent
tsv = pathlib.Path(os.environ.get("FIXTURE_VM_DIR", pathlib.Path.home() / ".cache/nas-fixture-vm")) / "results.tsv"
superseded = {"BD-AC-45"}  # first, undifferentiated record replaced by the split rows

rows = collections.OrderedDict()
for line in tsv.read_text().splitlines():
    parts = line.split("\t")
    if len(parts) < 3 or parts[0] in superseded:
        continue
    rows[parts[0]] = parts

counts = collections.Counter(r[1] for r in rows.values())
out = ["# VM fixture results (T-27 to T-30)", ""]
out.append(
    f"{counts['PASS']} PASS, {counts['FAIL']} FAIL, {counts['SKIPPED']} SKIPPED "
    f"({len(rows)} scenario rows). Guest: openSUSE Tumbleweed aarch64 (qemu/HVF), see README.md for what that does not prove."
)
out += ["", "| Scenario | Result | Evidence |", "|---|---|---|"]
for name, res, ev, *_ in rows.values():
    out.append(f"| {name} | {res} | {ev.replace('|', '/')} |")
notes = here / "RESULTS-notes.md"
out += ["", notes.read_text() if notes.exists() else ""]
(here / "RESULTS.md").write_text("\n".join(out))
print(dict(counts), file=sys.stderr)
