#!/bin/bash
# Static gate for the backup feature (PLAN-backup.md T-25): every [S] scenario
# that is a lint, grep, diff or list-tasks check, in one command. Prints one
# PASS / FAIL / SKIPPED line per scenario id and exits non-zero if any FAIL.
# Touches no host: syntax-check and list-tasks only; the vault password is a
# dummy unless a real one is passed for the decrypted-vault checks.
#
# Usage: tests/static-checks.sh            (from anywhere)
# Environment:
#   STATIC_CHECKS_BASE=master              ref for the AC-02/11/15 diffs
#                                          (falls back to origin/master; the
#                                          merge-base with HEAD is used)
#   STATIC_CHECKS_VAULT_PASSWORD_FILE=...  opt in to the decrypted-vault checks
#                                          (AC-09 values, AC-16 values); without
#                                          it they print SKIPPED, never PASS
#   STATIC_CHECKS_SKIP_RENDER=1            skip AC-07 (CI runs render-check.sh as
#                                          its own step)
#   YAMLLINT, ANSIBLE_LINT, PYTEST         command overrides, e.g.
#                                          ANSIBLE_LINT="pipx run ansible-lint"
set -u

nas_dir=$(cd "$(dirname "$0")/.." && pwd)
repo=$(git -C "$nas_dir" rev-parse --show-toplevel)
cloud_dir="$repo/cloud-wahlberger-dev"
nas_rel=${nas_dir#"$repo"/}
cloud_rel=${cloud_dir#"$repo"/}

YAMLLINT=${YAMLLINT:-yamllint}
ANSIBLE_LINT=${ANSIBLE_LINT:-ansible-lint}
PYTEST=${PYTEST:-pytest}
# Split once into arrays so a multi-word override ("pipx run ansible-lint")
# works while every expansion below stays quoted.
read -r -a yamllint_cmd <<<"$YAMLLINT"
read -r -a ansible_lint_cmd <<<"$ANSIBLE_LINT"
read -r -a pytest_cmd <<<"$PYTEST"

base=${STATIC_CHECKS_BASE:-master}
if ! git -C "$repo" rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
    base="origin/$base"
fi
# Diff against the merge-base, not the moving tip: master keeps receiving
# unrelated commits (Renovate bumps, other directories) that `git diff master`
# would report as this branch's changes.
base=$(git -C "$repo" merge-base HEAD "$base") || { echo "static-checks: cannot resolve base ref" >&2; exit 2; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/static-checks.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

# Never decrypt real secrets by accident (and never call the 1Password script).
echo "ci-cannot-decrypt-this-is-expected" >"$tmp/dummy-vault-pass"
export ANSIBLE_VAULT_PASSWORD_FILE="$tmp/dummy-vault-pass"
export ANSIBLE_FORCE_COLOR=0 ANSIBLE_NOCOLOR=1

fails=0
pass() { printf 'PASS    %-8s %s\n' "$1" "$2"; }
skip() { printf 'SKIPPED %-8s %s\n' "$1" "$2"; }
fail() { printf 'FAIL    %-8s %s\n' "$1" "$2"; fails=$((fails + 1)); }

# check <id> <description> <function>: the function prints its findings on
# stdout/stderr and returns 0 (pass), 1 (fail) or 77 (skipped).
check() {
    id=$1 desc=$2 fn=$3
    out=$("$fn" 2>&1)
    rc=$?
    case $rc in
    0) pass "$id" "$desc" ;;
    77) skip "$id" "$desc: $out" ;;
    *)
        fail "$id" "$desc"
        printf '%s\n' "$out" | sed 's/^/        /'
        ;;
    esac
}

# run_step <label> <dir> <cmd...>: runs a command, prints its output only on failure.
run_step() {
    label=$1 dir=$2
    shift 2
    if o=$(cd "$dir" && "$@" 2>&1); then
        return 0
    fi
    printf '[%s] failed: %s\n%s\n' "$label" "$*" "$o"
    return 1
}

# Files "R" of BD-AC-04: role tasks/handlers/templates/files, inventory vars, site.yml.
r_files() {
    (
        cd "$nas_dir" || exit 1
        find roles/*/tasks roles/*/handlers roles/*/templates roles/*/files \
            inventories/*/group_vars inventories/*/host_vars -type f 2>/dev/null
        echo site.yml
    )
}

# --- BD-AC-01 (+ BD-NFR-02): lint triplet for both directories ---------------
ac01() {
    rc=0
    run_step "nas yamllint" "$nas_dir" "${yamllint_cmd[@]}" . || rc=1
    run_step "nas ansible-lint" "$nas_dir" "${ansible_lint_cmd[@]}" || rc=1
    run_step "nas site.yml syntax" "$nas_dir" ansible-playbook site.yml --syntax-check || rc=1
    run_step "nas backup_disk_init.yml syntax" "$nas_dir" ansible-playbook backup_disk_init.yml --syntax-check || rc=1
    run_step "cloud yamllint" "$cloud_dir" "${yamllint_cmd[@]}" . || rc=1
    run_step "cloud ansible-lint" "$cloud_dir" "${ansible_lint_cmd[@]}" || rc=1
    run_step "cloud site.yml syntax" "$cloud_dir" ansible-playbook site.yml --syntax-check || rc=1
    return $rc
}

# --- BD-AC-02 (+ BD-NFR-03): no lint suppression added -----------------------
# static-checks.sh is excluded: its own grep pattern contains the keywords.
ac02() {
    d=$(git -C "$repo" diff "$base" -- "$nas_rel" "$cloud_rel" ":(exclude)$nas_rel/reqs" \
        ":(exclude)$nas_rel/tests/static-checks.sh" ":(exclude)$nas_rel/PLAN-backup.md" ":(exclude,glob)$nas_rel/tests/**/*.py") || { echo "git diff against $base failed"; return 1; }
    hits=$(printf '%s\n' "$d" | grep -E '^\+.*(noqa|skip_list|warn_list)')
    [ -z "$hits" ] || { printf '%s\n' "$hits"; return 1; }
}

# --- BD-AC-04: destructive operations unreachable from site.yml --------------
ac04() {
    rc=0
    cd "$nas_dir" || return 1
    files=$(r_files)
    # (a) the spec pattern, verbatim, split in two so the allowed cases fall out:
    #     everything except chattr must live in roles/backup_disk/tasks/init*.yml;
    #     chattr is tolerated outside init only when it does not set +C.
    pat_a='community\.general\.(parted|filesystem|btrfs_subvolume)|mkfs|wipefs|sgdisk|sfdisk|\bparted\b|\bdd\b|blkdiscard|shred|cryptsetup|btrfs (device (add|delete|remove)|replace)|subvolume (create|delete)'
    # shellcheck disable=SC2086
    a=$(grep -nE "$pat_a" $files | grep -vE '^roles/backup_disk/tasks/init[^:]*\.yml:')
    [ -z "$a" ] || { echo "(a) destructive pattern outside roles/backup_disk/tasks/init*.yml:"; echo "$a"; rc=1; }
    # shellcheck disable=SC2086
    a2=$(grep -nE 'chattr.*\+[a-zA-Z]*C' $files | grep -vE '^roles/backup_disk/tasks/init[^:]*\.yml:')
    [ -z "$a2" ] || { echo "(a) chattr +C outside init*.yml:"; echo "$a2"; rc=1; }
    # (b) static include/import names; none templated, none naming an init file.
    # shellcheck disable=SC2086
    # Comment lines may mention `{{` without naming a file, so only code lines are tested for it.
    b0=$(grep -nE '(include|import)_(tasks|role|playbook)' $files)
    b=$(printf '%s\n' "$b0" | grep -E '(^|[^a-z_])init([^a-z]|$)|init[a-z_-]*\.yml'
        printf '%s\n' "$b0" | grep -vE ':[0-9]+:[[:space:]]*#' | grep -F '{{')
    [ -z "$b" ] || { echo "(b) templated or init include/import:"; echo "$b"; rc=1; }
    # (c) backup_disk_init_confirm only read, never defined as a YAML key.
    c=$(grep -rn 'backup_disk_init_confirm' inventories/ roles/*/defaults roles/*/vars ./*.yml 2>/dev/null \
        | grep -E 'backup_disk_init_confirm[[:space:]]*:')
    [ -z "$c" ] || { echo "(c) backup_disk_init_confirm defined:"; echo "$c"; rc=1; }
    # (d) no force flags in the init tasks.
    d=$(grep -nE '(-f|--force)\b' roles/backup_disk/tasks/init*.yml)
    [ -z "$d" ] || { echo "(d) force flag in init tasks:"; echo "$d"; rc=1; }
    # backup_disk_init.yml exists and has a single play with hosts: nas.
    python3 - <<'PY' || rc=1
import sys, yaml
try:
    plays = yaml.safe_load(open("backup_disk_init.yml"))
except OSError as e:
    sys.exit(f"backup_disk_init.yml: {e}")
if not (isinstance(plays, list) and len(plays) == 1 and plays[0].get("hosts") == "nas"):
    sys.exit("backup_disk_init.yml must contain exactly one play with hosts: nas")
PY
    return $rc
}

# --- BD-AC-05: role order and tags -------------------------------------------
ac05() {
    cd "$nas_dir" || return 1
    python3 - <<'PY'
import os, re, subprocess, sys

def list_tasks(*extra):
    p = subprocess.run(["ansible-playbook", "site.yml", "--list-tasks", *extra],
                       capture_output=True, text=True)
    if p.returncode:
        sys.exit(f"ansible-playbook --list-tasks {' '.join(extra)} failed:\n{p.stdout}{p.stderr}")
    return [m.group(1) for l in p.stdout.splitlines() if (m := re.match(r"\s+(\w+) : ", l))]

order = list_tasks()
first = {}
for i, r in enumerate(order):
    first.setdefault(r, i)
errors = []
def before(a, b):
    for r in (a, b):
        if r not in first:
            errors.append(f"role {r} has no task in site.yml --list-tasks")
            return
    if not first[a] < first[b]:
        errors.append(f"{a} must come before {b}")
for a, b in [("notify_failure", "smartd"), ("smartd", "backup_disk"), ("storage", "backup_disk"), ("backup_disk", "snapper"),
             ("firewall", "restic_server"), ("podman", "restic_server"), ("storage", "restic_server"),
             ("paperless_ngx", "db_dump"), ("immich", "db_dump"), ("tandoor", "db_dump"), ("forgejo", "db_dump"),
             ("paperless_ngx", "btrbk"), ("immich", "btrbk"), ("tandoor", "btrbk"), ("forgejo", "btrbk"),
             ("db_dump", "btrbk"), ("backup_disk", "btrbk")]:
    before(a, b)
for role in ("smartd", "backup_disk", "restic_server", "db_dump", "btrbk", "restic_backup_decommission"):
    if role not in list_tasks("--tags", role):
        errors.append(f"--tags {role} --list-tasks lists no {role} task")
if errors:
    sys.exit("\n".join(errors))
PY
}

# --- BD-AC-06: defaults vs argument_specs ------------------------------------
ac06() {
    cd "$nas_dir" || return 1
    python3 - "$base" <<'PY'
import glob, os, subprocess, sys, yaml

base = sys.argv[1]

def git(*a):
    return subprocess.run(["git", *a], capture_output=True, text=True, check=True).stdout.split()

# Scope: roles the feature adds or touches (defaults/ or meta/), plus the two
# the scenario names. Older untouched roles are not retrofitted.
touched = {"backup_disk", "firewall"}
for path in git("diff", "--name-only", base, "--", "roles") + git("ls-files", "-o", "--exclude-standard", "roles"):
    parts = path.split("/")
    if parts[0] == "roles" and len(parts) > 3 and parts[2] in ("defaults", "meta"):
        touched.add(parts[1])
errors = []
for defaults in sorted(glob.glob("roles/*/defaults/main.yml")):
    role = defaults.split("/")[1]
    if role not in touched:
        continue
    specs_file = f"roles/{role}/meta/argument_specs.yml"
    d = yaml.safe_load(open(defaults)) or {}
    if not os.path.exists(specs_file):
        errors.append(f"{role}: meta/argument_specs.yml missing")
        continue
    specs = (yaml.safe_load(open(specs_file)) or {}).get("argument_specs") or {}
    declared = {}
    for entry in specs.values():
        declared.update(entry.get("options") or {})
    for key in d:
        if key not in declared:
            errors.append(f"{role}: default {key} not declared in argument_specs")
    for name, opt in declared.items():
        for need in ("type", "description"):
            if not (opt or {}).get(need):
                errors.append(f"{role}: option {name} lacks {need}")
    if role == "backup_disk" and not {"main", "init"} <= set(specs):
        errors.append(f"backup_disk: entry points {sorted(specs)} must include main and init")
    if role == "firewall" and "firewall_rich_rules" not in declared:
        errors.append("firewall: firewall_rich_rules not declared")
if errors:
    sys.exit("\n".join(errors))
PY
}

# --- BD-AC-07: render check (both runs of the spec) --------------------------
ac07() {
    [ "${STATIC_CHECKS_SKIP_RENDER:-}" != 1 ] || { echo "STATIC_CHECKS_SKIP_RENDER=1 (run tests/render-check.sh separately)"; return 77; }
    rc=0
    run_step "render-check" "$nas_dir" tests/render-check.sh || rc=1
    run_step "render-check spindown" "$nas_dir" tests/render-check.sh -e backup_disk_hdparm_spindown=120 || rc=1
    return $rc
}

# --- BD-AC-08: rest-server image pinned and Renovate-detectable --------------
ac08() {
    cd "$nas_dir" || return 1
    python3 - "$repo/renovate.json" <<'PY'
import json, re, sys

cfg = json.load(open(sys.argv[1]))
pattern = cfg["customManagers"][0]["matchStrings"][0]
# Renovate uses JS named groups (?<n>...); Python wants (?P<n>...).
m = re.search(re.sub(r"\(\?<(\w+)>", r"(?P<\1>", pattern),
              open("roles/restic_server/defaults/main.yml").read())
if not m:
    sys.exit("restic_server_image line does not match the first renovate.json custom manager")
if (m["depName"], m["currentValue"]) != ("docker.io/restic/rest-server", "0.14.0"):
    sys.exit(f"matched depName={m['depName']} currentValue={m['currentValue']}; "
             "expected docker.io/restic/rest-server 0.14.0")
PY
}

# --- BD-AC-09 (non-vault part): vars, flags, example placeholders ------------
ac09() {
    cd "$nas_dir" || return 1
    vars=inventories/production/group_vars/all/vars.yml
    rc=0
    # BD-FR-84. The spec's bare grep also matches the BD-FR-157 flag line, so
    # that one line is filtered (PLAN-backup.md, "Spec defect, BD-AC-09").
    g=$(grep -nE '^\s*restic_backup_' "$vars" | grep -v '^[0-9]*:restic_backup_decommission_enabled:')
    [ -z "$g" ] || { echo "restic_backup_ variables in vars.yml:"; echo "$g"; rc=1; }
    python3 - "$vars" inventories/production/group_vars/all/vault.yml.example <<'PY' || rc=1
import re, sys, yaml

vars_path, example_path = sys.argv[1:3]
text = open(vars_path).read()
lines = text.splitlines()
v = yaml.safe_load(text)
errors = []

def comment_above(lines, key_re):
    """Contiguous comment block directly above the first line matching key_re."""
    for i, l in enumerate(lines):
        if re.match(key_re, l):
            block = []
            j = i - 1
            while j >= 0 and lines[j].lstrip().startswith("#"):
                block.append(lines[j]); j -= 1
            return " ".join(block).lower()
    return None

for key, step in (("backup_disk_enabled", "step 3"), ("restic_backup_decommission_enabled", "step 5")):
    if v.get(key) is not False:
        errors.append(f"{key} must be false")
    c = comment_above(lines, rf"{key}:")
    if not c or step not in c:
        errors.append(f"{key} needs a comment naming runbook {step}")
if v.get("disk_space_paths") != ["/", "/mnt/data", "/mnt/containers", "/mnt/backup/btrbk"]:
    errors.append(f"disk_space_paths is {v.get('disk_space_paths')}")
if v.get("restic_server_clients") != [{"username": "cloud",
        "password": "{{ vault_restic_server_cloud_htpasswd_password | default('') }}"}]:
    errors.append("restic_server_clients differs from BD-FR-138")
if v.get("restic_server_maintenance_repo_password") != "{{ vault_restic_server_cloud_repo_password | default('') }}":
    errors.append("restic_server_maintenance_repo_password differs from BD-FR-139")
if v.get("restic_server_allowed_sources") != ["10.10.0.0/16", "10.243.0.0/16"]:
    errors.append("restic_server_allowed_sources must be [10.10.0.0/16, 10.243.0.0/16]")
if not comment_above(lines, r"firewall_rich_rules:"):
    errors.append("firewall_rich_rules needs the BD-FR-141 comment")

ex = open(example_path).read().splitlines()
for key, needle in (("vault_restic_backup_repo_password", "frozen"),
                    ("vault_restic_backup_rest_server_password", "frozen"),
                    ("vault_restic_server_cloud_htpasswd_password", "vault_restic_backup_rest_server_password"),
                    ("vault_restic_server_cloud_repo_password", "vault_restic_backup_repo_password")):
    c = comment_above(ex, rf"{key}:")
    if c is None:
        errors.append(f"vault.yml.example lacks {key}")
    elif needle not in c:
        errors.append(f"vault.yml.example comment of {key} must mention '{needle}'")
if errors:
    sys.exit("\n".join(errors))
PY
    # firewall_rich_rules evaluates to one BD-FR-109 rule per allowed source.
    ansible localhost -c local -i localhost, -e @roles/restic_server/defaults/main.yml -e @"$vars" \
        -m ansible.builtin.debug -a var=firewall_rich_rules >"$tmp/rules.out" 2>&1
    python3 - "$tmp/rules.out" <<'PY' || rc=1
import json, re, sys

raw = open(sys.argv[1]).read()
m = re.search(r"=> (\{.*\})", raw, re.S)
if not m:
    sys.exit("could not evaluate firewall_rich_rules:\n" + raw)
rules = json.loads(m.group(1))["firewall_rich_rules"]
want = [f'rule family="ipv4" source address="{s}" port port="8000" protocol="tcp" accept'
        for s in ("10.10.0.0/16", "10.243.0.0/16")]
if rules != want:
    sys.exit(f"firewall_rich_rules evaluates to {rules}, expected {want}")
PY
    return $rc
}

# --- BD-AC-09 / BD-AC-16 (decrypted part): needs the real vault password -----
vault_pw() {
    pw=${STATIC_CHECKS_VAULT_PASSWORD_FILE:-}
    [ -n "$pw" ] && [ -r "$pw" ] || return 1
    ansible-vault view --vault-password-file "$pw" \
        "$nas_dir/inventories/production/group_vars/all/vault.yml" >/dev/null 2>&1
}

ac09_vault() {
    vault_pw || { echo "no vault access"; return 77; }
    python3 - "$STATIC_CHECKS_VAULT_PASSWORD_FILE" "$nas_dir" "$cloud_dir" <<'PY'
import hashlib, subprocess, sys, yaml

pw, nas, cloud = sys.argv[1:4]
def load(d):
    p = subprocess.run(["ansible-vault", "view", "--vault-password-file", pw,
                        f"{d}/inventories/production/group_vars/all/vault.yml"],
                       capture_output=True, text=True)
    if p.returncode:
        sys.exit(f"cannot decrypt {d} vault.yml")
    return yaml.safe_load(p.stdout) or {}
n, c = load(nas), load(cloud)
errors = []
for k in ("vault_restic_backup_repo_password", "vault_restic_backup_rest_server_password",
          "vault_restic_server_cloud_htpasswd_password", "vault_restic_server_cloud_repo_password"):
    if not n.get(k):
        errors.append(f"nas vault.yml lacks {k}")
# BD-BR-09 equalities; compared as digests, values are never printed.
h = lambda s: hashlib.sha256(str(s).encode()).hexdigest()
for a, b in (("vault_restic_server_cloud_htpasswd_password", "vault_restic_backup_rest_server_password"),
             ("vault_restic_server_cloud_repo_password", "vault_restic_backup_repo_password")):
    if n.get(a) is None or c.get(b) is None or h(n[a]) != h(c[b]):
        errors.append(f"nas {a} must equal cloud {b}")
if errors:
    sys.exit("\n".join(errors))
PY
}

# --- BD-AC-10: the NAS restic_backup role is gone ----------------------------
ac10() {
    a=$(git -C "$repo" ls-files "$nas_rel/roles/restic_backup")
    b=$(grep -nE 'role:\s*restic_backup\b' "$nas_dir/site.yml")
    [ -z "$a$b" ] || { printf '%s\n%s\n' "$a" "$b"; return 1; }
}

# --- BD-AC-11: the Pi is untouched and never contacted -----------------------
ac11() {
    rc=0
    a=$(git -C "$repo" diff "$base" --stat -- pi-de-int-wahlberger-dev)
    [ -z "$a" ] || { echo "pi-de-int-wahlberger-dev changed:"; echo "$a"; rc=1; }
    # Only cloud's pre-cut-over default restic_backup_rest_server_host may match.
    b=$(git -C "$repo" diff "$base" -- "$nas_rel" "$cloud_rel" ':(exclude)*.md' \
        | grep -E '^\+.*pi\.de\.int\.wahlberger\.dev' | grep -v 'restic_backup_rest_server_host')
    [ -z "$b" ] || { echo "added references to the Pi:"; echo "$b"; rc=1; }
    return $rc
}

# --- BD-AC-14: no NAS document describes the old job as deployed -------------
# Excluded beyond the spec: PLAN-backup.md (the plan for this very change),
# caches, this script (its patterns contain the search words) and
# tests/vm/scenarios (VM scenario scripts that create a dummy old job to prove
# its removal, BD-AC-25/38).
ac14() {
    cd "$repo" || return 1
    m=$(grep -rn -i 'restic_backup\|restic-backup' "$nas_rel" --exclude-dir=reqs --exclude-dir=.ansible \
        --exclude-dir=.ansible_cache --exclude-dir=.pytest_cache --exclude-dir=.ruff_cache \
        --exclude=PLAN.md --exclude=PLAN-backup.md --exclude=static-checks.sh --exclude-dir=scenarios \
        | grep -v "^$nas_rel/roles/restic_backup_decommission/")
    printf '%s\n' "$m" | python3 -c '
import re, sys
# Allowed (BD-AC-14), each kind named explicitly:
#  1. the decommission role or its flag (restic_backup_decommission...);
#  2. the restore-only vault keys of BD-FR-85;
#  3. cloud own restic_backup role, only as its path or as the phrase "cloud own";
#  4. the word "removed" (or removes/removal) on the same line as the match;
#  5. a runbook command run against cloud (`ssh cloud ...`).
# Kinds 1, 2, 4 and 5 are judged on the match line alone. Kind 3 needs the
# phrase on the line, or "cloud" within the 4 lines around it.
line_ok = re.compile(r"restic_backup_decommission|vault_restic_backup_(repo|rest_server)_password"
                     r"|cloud-wahlberger-dev/roles/restic_backup|cloud own|\bremoved\b|\bremoves\b|\bremoval\b"
                     r"|ssh cloud", re.I)
cloud_ctx = re.compile(r"\bcloud\b", re.I)
bad = []
for raw in sys.stdin:
    raw = raw.rstrip("\n")
    m = re.match(r"(.+?):(\d+):", raw)
    if not m:
        continue
    path, no = m.group(1), int(m.group(2))
    lines = open(path, errors="replace").read().splitlines()
    ctx = " ".join(lines[max(0, no - 5):no + 4])
    if not (line_ok.search(lines[no - 1]) or cloud_ctx.search(ctx)):
        bad.append(raw)
if bad:
    print("matches that do not describe the job as removed:")
    print("\n".join(bad))
    sys.exit(1)
'
}

# --- BD-AC-15: the snapper role is untouched ---------------------------------
ac15() {
    d=$(git -C "$repo" diff "$base" -- "$nas_rel/roles/snapper/")
    [ -z "$d" ] || { echo "$d" | head -20; return 1; }
}

# --- BD-AC-16: the VM fixture holds no production secret ---------------------
ac16() {
    cd "$nas_dir" || return 1
    python3 - <<'PY'
import sys, yaml
inv = yaml.safe_load(open("inventories/vm/hosts.yml"))
hosts = inv["all"]["children"]["nas"]["hosts"]
others = [g for g in inv["all"].get("children", {}) if g != "nas"]
if len(hosts) != 1 or others or inv["all"].get("hosts"):
    sys.exit("inventories/vm/hosts.yml must have exactly one host, in group nas")
PY
}

ac16_vault() {
    vault_pw || { echo "no vault access"; return 77; }
    python3 - "$STATIC_CHECKS_VAULT_PASSWORD_FILE" "$nas_dir" <<'PY'
import os, subprocess, sys, yaml

pw, nas = sys.argv[1:3]
p = subprocess.run(["ansible-vault", "view", "--vault-password-file", pw,
                    f"{nas}/inventories/production/group_vars/all/vault.yml"],
                   capture_output=True, text=True)
if p.returncode:
    sys.exit("cannot decrypt vault.yml")
values = [str(v) for v in (yaml.safe_load(p.stdout) or {}).values() if isinstance(v, (str, int)) and len(str(v)) >= 4]
blob = ""
for root, _, files in os.walk(f"{nas}/inventories/vm"):
    for f in files:
        blob += open(os.path.join(root, f), errors="replace").read()
leaks = sum(1 for v in values if v in blob)
if leaks:
    sys.exit(f"{leaks} production vault value(s) appear in inventories/vm/ (values not shown)")
PY
}

# --- pytest tests/unit --------------------------------------------------------
unit() { run_step "pytest" "$nas_dir" "${pytest_cmd[@]}" tests/unit -q; }

echo "static checks, diff base: $(git -C "$repo" rev-parse --short "$base")"
check AC-01 "yamllint, ansible-lint, syntax-check (nas + cloud)" ac01
check AC-02 "no noqa/skip_list/warn_list added" ac02
check AC-04 "destructive operations unreachable from site.yml" ac04
check AC-05 "role order and tags (list-tasks)" ac05
check AC-06 "defaults vs argument_specs" ac06
check AC-07 "render check (default and spindown 120)" ac07
check AC-08 "rest-server image Renovate-detectable" ac08
check AC-09 "vars, flags and vault.yml.example wiring" ac09
check AC-09v "decrypted vault keys and BD-BR-09 equalities" ac09_vault
check AC-10 "restic_backup role gone" ac10
check AC-11 "Pi untouched and never contacted" ac11
check AC-14 "no NAS doc describes the old job as deployed" ac14
check AC-15 "snapper role untouched" ac15
check AC-16 "VM fixture inventory shape" ac16
check AC-16v "no production vault value in inventories/vm" ac16_vault
check UNIT "pytest tests/unit" unit

if [ "$fails" -gt 0 ]; then
    echo "static checks: $fails FAILED"
    exit 1
fi
echo "static checks: all passed (SKIPPED lines are not passes)"
