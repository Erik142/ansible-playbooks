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
    # yamllint, ansible-lint and site.yml syntax run in the CI validate job.
    # Only backup_disk_init.yml is not covered there.
    run_step "nas backup_disk_init.yml syntax" "$nas_dir" ansible-playbook backup_disk_init.yml --syntax-check
}

# --- BD-AC-02 (+ BD-NFR-03): no lint suppression added -----------------------
# Scope is the whole repo's added lines, minus Markdown (specs and docs name the
# markers on purpose). Nothing else is excluded: an excluded path is a bypass.
# The marker list is assembled from pieces so this file's own added lines do
# not contain the literal words the pattern searches for.
ac02() {
    kw="no""qa|skip""_list|warn""_list|yamllint[[:space:]]+disable|shellcheck[[:space:]]+disable|pylint:[[:space:]]*disable"
    d=$(git -C "$repo" diff "$base" -- ':(exclude)*.md') || { echo "git diff against $base failed"; return 1; }
    # Keep added content lines only ("+++ b/<path>" headers are not content).
    # Extended regex throughout: in basic regex `\+` is a repetition operator,
    # so a bad pattern here used to make grep fail and the check pass silently.
    hits=$(printf '%s\n' "$d" | grep -E '^\+' | grep -vE '^\+\+\+ ' | grep -iE "$kw")
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
    # A0 carve-out (garage, GS-FR-02): roles/garage/tasks/storage.yml alone may
    # contain `btrfs subvolume create`; nothing else, in no other file.
    a=$(grep -nE "$pat_a" $files | grep -vE '^roles/backup_disk/tasks/init[^:]*\.yml:' \
        | grep -vE '^roles/garage/tasks/storage\.yml:[0-9]+:.*btrfs subvolume create')
    [ -z "$a" ] || { echo "(a) destructive pattern outside roles/backup_disk/tasks/init*.yml:"; echo "$a"; rc=1; }
    # shellcheck disable=SC2086
    # A0 carve-out (garage, GS-FR-06): roles/garage/tasks/storage.yml alone may set +C.
    a2=$(grep -nE 'chattr.*\+[a-zA-Z]*C' $files | grep -vE '^roles/backup_disk/tasks/init[^:]*\.yml:' \
        | grep -vE '^roles/garage/tasks/storage\.yml:')
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

# --- GS-AC-74: the garage role runs no state-changing Garage command (GS-FR-138)
ac_garage_no_state() {
    cd "$nas_dir" || return 1
    g=$(grep -rnE 'layout (assign|apply)|bucket (create|allow|deny|website)|set-quotas|key (create|import)|put-bucket-lifecycle|lifecycle' \
        roles/garage/tasks roles/garage/templates 2>/dev/null)
    [ -z "$g" ] || { echo "garage role runs a layout/bucket/key/grant/quota/website/lifecycle command:"; echo "$g"; return 1; }
    # The only /garage subcommand in the tasks is `status`.
    g2=$(grep -rnoE '/garage +[a-z][a-z-]*' roles/garage/tasks | grep -vE '/garage +status$')
    [ -z "$g2" ] || { echo "garage tasks use a /garage subcommand other than status:"; echo "$g2"; return 1; }
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
             ("db_dump", "btrbk"), ("backup_disk", "btrbk"),
             ("garage", "caddy"), ("garage", "btrbk")]:
    before(a, b)
for role in ("smartd", "backup_disk", "restic_server", "db_dump", "btrbk", "restic_backup_decommission", "garage"):
    if role not in list_tasks("--tags", role):
        errors.append(f"--tags {role} --list-tasks lists no {role} task")
# GS-AC-39: garage is gated and tagged.
import yaml
entries = [e for p in yaml.safe_load(open("site.yml")) for e in p.get("roles", [])
           if isinstance(e, dict) and e.get("role") == "garage"]
if len(entries) != 1:
    errors.append("site.yml must contain exactly one `role: garage` entry")
elif entries[0].get("tags") != ["garage"] or entries[0].get("when") != "garage_enabled | bool":
    errors.append("site.yml garage entry needs `tags: [garage]` and `when: garage_enabled | bool`")
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
# The invariant: the pin is detected as rest-server and carries a version. The
# version itself is Renovate's to change, so it is not compared to a fixed value.
if m["depName"] != "docker.io/restic/rest-server":
    sys.exit(f"matched depName={m['depName']}; expected docker.io/restic/rest-server")
if not re.fullmatch(r"\d+\.\d+\.\d+", m["currentValue"]):
    sys.exit(f"currentValue={m['currentValue']} is not an x.y.z version")
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
    python3 - "$vars" inventories/production/group_vars/all/vault.yml.example "$nas_dir" "$repo" <<'PY' || rc=1
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
    if not isinstance(v.get(key), bool):
        errors.append(f"{key} must be a boolean (false until its runbook step, true after the 2026-10-10 cut-over)")
    c = comment_above(lines, rf"{key}:")
    if not c or step not in c:
        errors.append(f"{key} needs a comment naming runbook {step}")
# The expected lists are read from the specs (single source of truth); vars.yml
# and vault.yml.example must agree with them. Changing a list means changing
# the spec line it is read from, not this check.
nas, repo = sys.argv[3:5]
cut = f"{nas}/reqs/backup-cutover-and-decommission.md"
sem = f"{repo}/semaphore-migration/reqs/semaphore-to-hetzner.md"

def spec_line(path, marker):
    hits = [l for l in open(path, encoding="utf-8").read().splitlines() if marker in l]
    if len(hits) != 1:
        sys.exit(f"{path}: expected one line containing {marker!r}, found {len(hits)}")
    return hits[0]

ex_text = open(example_path).read()

# disk_space_paths: BD-AC-09 lists the exact paths.
want_paths = re.findall(r"`(/[^`]*)`", spec_line(cut, "And `disk_space_paths` lists"))
if not want_paths or sorted(v.get("disk_space_paths") or []) != sorted(want_paths):
    errors.append(f"disk_space_paths is {v.get('disk_space_paths')}, BD-AC-09 (BD-FR-45) lists {want_paths}")

# restic_server_allowed_sources: the literal list in BD-FR-141.
lit = re.search(r"`restic_server_allowed_sources: (\[[^`]*\])`", spec_line(cut, "BD-FR-141 [Must]"))
if not lit:
    sys.exit("BD-FR-141 has no restic_server_allowed_sources literal")
want_sources = yaml.safe_load(lit.group(1))
if v.get("restic_server_allowed_sources") != want_sources:
    errors.append(f"restic_server_allowed_sources is {v.get('restic_server_allowed_sources')}, BD-FR-141 says {want_sources}")

# restic_server_clients: BD-FR-138 gives the cloud entry verbatim. Every client
# has a vault placeholder (BD-FR-140), so the usernames are those placeholders.
lit = re.search(r"`(\{username:[^`]*\})`", spec_line(cut, "BD-FR-138 [Must]"))
if not lit:
    sys.exit("BD-FR-138 has no {username: ...} literal")
clients = v.get("restic_server_clients") or []
if yaml.safe_load(lit.group(1)) not in clients:
    errors.append("restic_server_clients lacks the BD-FR-138 cloud entry")
users = sorted(set(re.findall(r"^vault_restic_server_(\w+?)_htpasswd_password:", ex_text, re.M)))
if not users:
    errors.append("vault.yml.example has no restic_server_* htpasswd placeholder")
want_clients = [{"username": u, "password": "{{ vault_restic_server_" + u + "_htpasswd_password | default('') }}"} for u in users]
if sorted(clients, key=lambda e: str(e.get("username"))) != sorted(want_clients, key=lambda e: e["username"]):
    errors.append(f"restic_server_clients is {clients}, vault.yml.example placeholders give {want_clients}")

# restic_server_maintenance_repos: SH-CC-01 names the repositories
# ("production `cloud` and `ops`"); each password is that repo's vault key.
sh = spec_line(sem, "- SH-CC-01 (NAS")
want_repos = re.findall(r"`([A-Za-z0-9_.-]+)`", sh.split("production", 1)[1].split(". ", 1)[0])
repos = v.get("restic_server_maintenance_repos") or []
if not want_repos or sorted(str(r.get("repo")) for r in repos) != sorted(want_repos):
    errors.append(f"restic_server_maintenance_repos names {[r.get('repo') for r in repos]}, SH-CC-01 names {want_repos}")
for r in repos:
    if r.get("password") != "{{ vault_restic_server_" + str(r.get("repo")) + "_repo_password | default('') }}":
        errors.append(f"maintenance repo {r.get('repo')}: password must be its vault_restic_server_<repo>_repo_password")
repo_keys = set(re.findall(r"^vault_restic_server_(\w+?)_repo_password:", ex_text, re.M))
for name in want_repos:
    if name not in repo_keys:
        errors.append(f"vault.yml.example lacks vault_restic_server_{name}_repo_password")

fc = v.get("backup_disk_freshness_checks") or []
if isinstance(fc, str):
    # Jinja expression (Garage entries are appended behind garage_enabled).
    ops_ok = re.search(r"/mnt/data/restic-repos/ops/snapshots['\"]\s*,\s*['\"]max_age_hours['\"]\s*:\s*26\b", fc) is not None
else:
    ops_ok = {"path": "/mnt/data/restic-repos/ops/snapshots", "max_age_hours": 26} in fc
if not ops_ok:
    errors.append("backup_disk_freshness_checks lacks the ops path (SH-FR-87)")
if not comment_above(lines, r"firewall_rich_rules:"):
    errors.append("firewall_rich_rules needs the BD-FR-141 comment")

ex = open(example_path).read().splitlines()
for key, needle in (("vault_restic_backup_repo_password", "frozen"),
                    ("vault_restic_backup_rest_server_password", "frozen"),
                    ("vault_restic_server_cloud_htpasswd_password", "vault_restic_backup_rest_server_password"),
                    ("vault_restic_server_cloud_repo_password", "vault_restic_backup_repo_password"),
                    ("vault_restic_server_ops_htpasswd_password", "vault_restic_backup_rest_server_password"),
                    ("vault_restic_server_ops_repo_password", "vault_restic_backup_repo_password")):
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
    python3 - "$tmp/rules.out" "$vars" <<'PY' || rc=1
import json, re, sys, yaml

raw = open(sys.argv[1]).read()
m = re.search(r"=> (\{.*\})", raw, re.S)
if not m:
    sys.exit("could not evaluate firewall_rich_rules:\n" + raw)
rules = json.loads(m.group(1))["firewall_rich_rules"]
# Expected: one rule per allowed source (the list the BD-FR-141 check above pins
# to the spec), on restic_server_port (the default, which the rule must match).
sources = yaml.safe_load(open(sys.argv[2]))["restic_server_allowed_sources"]
port = yaml.safe_load(open("roles/restic_server/defaults/main.yml"))["restic_server_port"]
want = [f'rule family="ipv4" source address="{s}" port port="{port}" protocol="tcp" accept'
        for s in sources]
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
check AC-01 "backup_disk_init.yml syntax (lint and site syntax: CI validate)" ac01
check AC-02 "no noqa/skip_list/warn_list added" ac02
check AC-04 "destructive operations unreachable from site.yml" ac04
check GS-AC-74 "garage role runs no layout/bucket/key/lifecycle command" ac_garage_no_state
check AC-05 "role order and tags (list-tasks)" ac05
check AC-06 "defaults vs argument_specs" ac06
check AC-07 "render check (default and spindown 120)" ac07
check AC-08 "rest-server image Renovate-detectable" ac08
check AC-09 "vars, flags and vault.yml.example wiring" ac09
check AC-09v "decrypted vault keys and BD-BR-09 equalities" ac09_vault
check AC-11 "Pi untouched and never contacted" ac11
check AC-16v "no production vault value in inventories/vm" ac16_vault
check UNIT "pytest tests/unit" unit

if [ "$fails" -gt 0 ]; then
    echo "static checks: $fails FAILED"
    exit 1
fi
echo "static checks: all passed (SKIPPED lines are not passes)"
