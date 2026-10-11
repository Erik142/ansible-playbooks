#!/bin/bash
# Static gate for the Semaphore-to-Hetzner feature (PLAN.md T-14): every [S]
# scenario that is a lint, grep, diff or parse check, in one command. Prints one
# PASS / FAIL / SKIPPED line per scenario id and exits non-zero if any FAIL.
# Touches no host and no network: syntax-check, list/grep/parse and the two
# offline guard tests only.
#
# Hermetic by construction: an EMPTY ANSIBLE_CONFIG (the playbook's ansible.cfg
# names .vault_pass.sh, which calls 1Password's `op`), a throwaway vault
# password, and nothing in here ever runs .vault_pass.sh or `op`.
#
# Usage: tests/static-checks.sh            (from anywhere)
# Environment:
#   STATIC_CHECKS_BASE=master              ref for the SH-FR-97 diff (falls back
#                                          to origin/master; merge-base is used)
#   STATIC_CHECKS_STAGE=A                  A (default; PR A .. C), D or E: which
#                                          row of BR-10 / FR-160 / FR-161 / AC-43
#                                          applies. SH-AC-43 runs only at E.
#   STATIC_CHECKS_VAULT_PASSWORD_FILE=...  opt in to the decrypted-vault check
#                                          (SH-AC-17v); without it: SKIPPED. The
#                                          values are never printed.
#   STATIC_CHECKS_PR=<A|A2|..>             also run pr-boundaries.sh for that PR
#   STATIC_CHECKS_ONLY=id,id               run only these ids (negative tests)
#   STATIC_CHECKS_SKIP_LINT=1              skip SH-AC-01L (CI has its own jobs)
#   STATIC_CHECKS_SKIP_RENDER=1            skip SH-AC-30r (render-check.sh)
#   STATIC_CHECKS_SKIP_CONTAINER_GUARDS=1  skip SH-GUARDS-C (the guards that need
#                                          Docker/Podman and some of them the network)
#   STATIC_CHECKS_SKIP_UNIT=1              skip UNIT (pytest tests/unit; also set
#                                          by the unit tests themselves)
#   VM_PUBLIC_IP=...                       SH-AC-23: must appear in the new key's from=
#   YAMLLINT, ANSIBLE_LINT, PYTEST         command overrides, e.g.
#                                          ANSIBLE_LINT="pipx run ansible-lint"
set -u

ops_dir=$(cd "$(dirname "$0")/.." && pwd)
repo=$(git -C "$ops_dir" rev-parse --show-toplevel)
nas_dir="$repo/nas-de-int-wahlberger-dev"
cloud_dir="$repo/cloud-wahlberger-dev"
ops_rel=${ops_dir#"$repo"/}
pi_rel=pi-de-int-wahlberger-dev

YAMLLINT=${YAMLLINT:-yamllint}
ANSIBLE_LINT=${ANSIBLE_LINT:-ansible-lint}
PYTEST=${PYTEST:-pytest}
read -r -a yamllint_cmd <<<"$YAMLLINT"
read -r -a ansible_lint_cmd <<<"$ANSIBLE_LINT"
read -r -a pytest_cmd <<<"$PYTEST"

stage=${STATIC_CHECKS_STAGE:-A}
case "$stage" in A | D | E) ;; *) echo "static-checks: STATIC_CHECKS_STAGE must be A, D or E" >&2; exit 2 ;; esac

base=${STATIC_CHECKS_BASE:-master}
if ! git -C "$repo" rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
    base="origin/$base"
fi
base=$(git -C "$repo" merge-base HEAD "$base") || { echo "static-checks: cannot resolve base ref" >&2; exit 2; }

command -v ansible-playbook >/dev/null 2>&1 || { echo "static-checks: ansible-playbook not on PATH" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "static-checks: python3 needs PyYAML (use the ansible venv)" >&2; exit 2; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/static-checks.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

: >"$tmp/ansible.cfg"
echo "ci-cannot-decrypt-this-is-expected" >"$tmp/dummy-vault-pass"
export ANSIBLE_CONFIG="$tmp/ansible.cfg"
export ANSIBLE_VAULT_PASSWORD_FILE="$tmp/dummy-vault-pass"
export ANSIBLE_FORCE_COLOR=0 ANSIBLE_NOCOLOR=1
# The guards read the stage from the environment (tests/guards.d/vm_vars.yml).
export STATIC_CHECKS_STAGE="$stage"
# Handed to the embedded python checks.
export SC_OPS="$ops_dir" SC_NAS="$nas_dir" SC_CLOUD="$cloud_dir" SC_REPO="$repo" SC_STAGE="$stage"

fails=0
pass() { printf 'PASS    %-10s %s\n' "$1" "$2"; }
skip() { printf 'SKIPPED %-10s %s\n' "$1" "$2"; }
fail() { printf 'FAIL    %-10s %s\n' "$1" "$2"; fails=$((fails + 1)); }

# check <id> <description> <function>: the function prints its findings on
# stdout/stderr and returns 0 (pass), 1 (fail) or 77 (skipped).
check() {
    id=$1 desc=$2 fn=$3
    if [ -n "${STATIC_CHECKS_ONLY:-}" ]; then
        case ",$STATIC_CHECKS_ONLY," in *",$id,"*) ;; *) return 0 ;; esac
    fi
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

run_step() { # <label> <dir> <cmd...>: prints the output only on failure
    label=$1 dir=$2
    shift 2
    if o=$(cd "$dir" && "$@" 2>&1); then return 0; fi
    printf '[%s] failed: %s\n%s\n' "$label" "$*" "$o"
    return 1
}

# --- SH-AC-01 (+ SH-FR-13, 143, 62): skeleton structure -----------------------
ac01() {
    python3 - <<'PY'
import os, sys, yaml

ops, nas, cloud = (os.environ[k] for k in ("SC_OPS", "SC_NAS", "SC_CLOUD"))
errors = []
want = ["common", "notify_failure", "disk_space", "ssh_authorized_keys", "security", "reboot_notify",
        "firewall", "podman", "zerotier", "beszel_agent", "cloudflare_dns", "caddy", "semaphore", "restic_backup"]

def load(path):
    try:
        with open(path) as f:
            return yaml.safe_load(f)
    except (OSError, yaml.YAMLError) as e:
        errors.append(f"{path}: {type(e).__name__}")
        return None

# SH-FR-13 / SH-FR-143: exactly these roles, in this order, each tagged with its name.
plays = load(f"{ops}/site.yml")
if not isinstance(plays, list) or len(plays) != 1:
    errors.append("site.yml must hold exactly one play")
else:
    roles = plays[0].get("roles") or []
    names = [r.get("role") if isinstance(r, dict) else r for r in roles]
    if names != want:
        errors.append(f"site.yml roles {names} != SH-FR-13 {want}")
    for r in roles:
        if not isinstance(r, dict) or r.get("tags") != [r.get("role")]:
            errors.append(f"site.yml role {r.get('role') if isinstance(r, dict) else r}: tags must be [<role name>] (SH-FR-143)")

# hosts.yml lists only ops.de.wahlberger.dev.
inv = load(f"{ops}/inventories/production/hosts.yml") or {}
hosts = list((inv.get("all") or {}).get("hosts") or {})
for g in ((inv.get("all") or {}).get("children") or {}).values():
    hosts += list((g or {}).get("hosts") or {})
if hosts != ["ops.de.wahlberger.dev"]:
    errors.append(f"hosts.yml hosts {hosts} != ['ops.de.wahlberger.dev']")

gv = f"{ops}/inventories/production/group_vars/all"
if sorted(os.listdir(gv)) != sorted(["vars.yml", "vault.yml", "vault.yml.example"]):
    errors.append(f"group_vars/all holds {sorted(os.listdir(gv))}, want vars.yml, vault.yml, vault.yml.example")
try:
    with open(f"{gv}/vault.yml", "rb") as f:
        if not f.readline().startswith(b"$ANSIBLE_VAULT;"):
            errors.append("group_vars/all/vault.yml is not Ansible-Vault encrypted")
except OSError:
    errors.append("group_vars/all/vault.yml missing")
try:
    if "op://DevOps/Ansible Vault - ops-de-wahlberger-dev/password" not in open(f"{ops}/.vault_pass.sh").read():
        errors.append(".vault_pass.sh does not read op://DevOps/Ansible Vault - ops-de-wahlberger-dev/password")
except OSError:
    errors.append(".vault_pass.sh missing")
for name in (".yamllint", ".ansible-lint", "README.md", "CLAUDE.md"):
    if not os.path.isfile(f"{ops}/{name}"):
        errors.append(f"{name} missing")

# SH-FR-62: every ssh_authorized_keys_list holds the same personal key.
blobs = {}
for label, d in (("nas", nas), ("cloud", cloud), ("ops", ops)):
    v = load(f"{d}/inventories/production/group_vars/all/vars.yml") or {}
    lst = v.get("ssh_authorized_keys_list") or []
    mine = [e.split()[1] for e in lst if isinstance(e, str) and len(e.split()) == 3
            and e.split()[0] == "ssh-ed25519" and e.split()[2] == "erikwahlberger@personal"]
    if len(mine) != 1:
        errors.append(f"{label}: ssh_authorized_keys_list must hold the personal key (erikwahlberger@personal) exactly once")
    blobs[label] = mine
if len({tuple(b) for b in blobs.values()}) != 1:
    errors.append("the personal key differs between nas, cloud and ops")
if errors:
    sys.exit("\n".join(errors))
PY
}

# --- SH-AC-01L: lint triplet (yamllint, ansible-lint, syntax-check) -----------
ac01l() {
    [ "${STATIC_CHECKS_SKIP_LINT:-}" != 1 ] || { echo "STATIC_CHECKS_SKIP_LINT=1 (CI validate job covers it)"; return 77; }
    rc=0
    run_step "ops yamllint" "$ops_dir" "${yamllint_cmd[@]}" . || rc=1
    run_step "ops ansible-lint" "$ops_dir" "${ansible_lint_cmd[@]}" || rc=1
    run_step "ops site.yml syntax" "$ops_dir" ansible-playbook -i inventories/production/hosts.yml site.yml --syntax-check || rc=1
    return $rc
}

# --- SH-AC-17 (structure part): vars wiring and the example file --------------
ac17() {
    python3 - <<'PY'
import os, re, sys, yaml

ops = os.environ["SC_OPS"]
gv = f"{ops}/inventories/production/group_vars/all"
errors = []
vars_text = open(f"{gv}/vars.yml").read()
v = yaml.safe_load(vars_text)
if v.get("semaphore_url") != "https://semaphore.de.int.wahlberger.dev":
    errors.append("vars.yml semaphore_url differs from SH-FR-42")
if v.get("semaphore_oidc_client_id") != "63093482-d2cc-4c77-89df-9f6ff78b160e":
    errors.append("vars.yml semaphore_oidc_client_id differs from SH-FR-45")
ex = yaml.safe_load(open(f"{gv}/vault.yml.example")) or {}
if not ex or not all(k.startswith("vault_") for k in ex):
    errors.append("vault.yml.example must hold only vault_* keys")
for k, val in ex.items():
    if val not in ("", None):
        errors.append(f"vault.yml.example {k} must be an empty placeholder")
# Every vault_* name referenced by a plaintext vars file must exist in the example.
for m in sorted(set(re.findall(r"\bvault_[a-z0-9_]+", vars_text))):
    if m not in ex:
        errors.append(f"vars.yml references {m} which vault.yml.example lacks")
if errors:
    sys.exit("\n".join(errors))
PY
}

# --- SH-AC-17v: decrypted vault keys (needs the real password) ----------------
# Two independent parsers, so the result does not rest on one: PyYAML on the
# decrypted text, and Ansible's own loader (an ad-hoc assert over hostvars).
# Values are never printed: only key names and "present/empty" are compared.
ac17v() {
    pw=${STATIC_CHECKS_VAULT_PASSWORD_FILE:-}
    [ -n "$pw" ] && [ -r "$pw" ] || { echo "no STATIC_CHECKS_VAULT_PASSWORD_FILE"; return 77; }
    vault="$ops_dir/inventories/production/group_vars/all/vault.yml"
    ansible-vault view --vault-password-file "$pw" "$vault" >/dev/null 2>&1 \
        || { echo "the given password does not decrypt vault.yml"; return 77; }
    python3 - "$pw" <<'PY' || return 1
import os, subprocess, sys, yaml

ops = os.environ["SC_OPS"]
gv = f"{ops}/inventories/production/group_vars/all"
p = subprocess.run(["ansible-vault", "view", "--vault-password-file", sys.argv[1], f"{gv}/vault.yml"],
                   capture_output=True, text=True)
if p.returncode:
    sys.exit("cannot decrypt vault.yml")
try:
    data = yaml.safe_load(p.stdout)   # never echo the YAML error: it quotes the plaintext line
except yaml.YAMLError:
    sys.exit("decrypted vault.yml is not valid YAML (details withheld)")
if not isinstance(data, dict):
    sys.exit("decrypted vault.yml is not a mapping")
want = set(yaml.safe_load(open(f"{gv}/vault.yml.example")))
errors = [f"vault.yml lacks {k}" for k in sorted(want - set(data))]
errors += [f"vault.yml has unexpected key {k}" for k in sorted(set(data) - want)]
errors += [f"vault.yml {k} is empty" for k in sorted(want & set(data)) if data[k] in (None, "")]
if errors:
    sys.exit("\n".join(errors))
PY
    names=$(python3 -c '
import sys, yaml
print(" ".join(yaml.safe_load(open(sys.argv[1]))))' "$ops_dir/inventories/production/group_vars/all/vault.yml.example") || return 1
    conds=""
    for n in $names; do conds="${conds}${conds:+,}\"$n is defined and ($n | string | length) > 0\""; done
    # Ansible's loader; `quiet` keeps values out of the output. Only failure text is shown, filtered.
    o=$(cd "$ops_dir" && ansible -c local -i inventories/production/hosts.yml ops.de.wahlberger.dev \
        --vault-password-file "$pw" -m ansible.builtin.assert -a "{\"that\": [$conds], \"quiet\": true}" 2>&1) \
        || { printf '%s\n' "$o" | grep -E "^\s+\"(assertion|evaluated_to)\"|FAILED|UNREACHABLE" | head -20; echo "Ansible's loader does not see every vault key as defined and non-empty"; return 1; }
}

# --- SH-AC-23 (+ SH-BR-10, SH-FR-62, 126): key lists and private keys ---------
ac23() {
    rc=0
    python3 - <<'PY' || rc=1
import ipaddress, os, re, sys, yaml

nas, cloud, ops = (os.environ[k] for k in ("SC_NAS", "SC_CLOUD", "SC_OPS"))
stage = os.environ["SC_STAGE"]
errors = []

def lst(d):
    v = yaml.safe_load(open(f"{d}/inventories/production/group_vars/all/vars.yml")) or {}
    return v, [e for e in (v.get("ssh_authorized_keys_list") or [])]

vn, ln = lst(nas)
vc, lc = lst(cloud)
vo, lo = lst(ops)

def comment(e):
    return e.split()[-1] if isinstance(e, str) and e.split() else ""

def kind(e):
    c = comment(e)
    if c == "erikwahlberger@personal":
        return "personal"
    if c == "semaphore-automation@ops.de.wahlberger.dev":
        return "new"
    if c.startswith("semaphore-automation@pi."):
        return "old"
    return "other:" + c

def kinds(l):
    return sorted(kind(e) for e in l)

if sorted(ln) != sorted(lc):
    errors.append("nas and cloud ssh_authorized_keys_list differ (SH-BR-10: identical at every step)")
new_in = {n: [e for e in l if kind(e) == "new"] for n, l in (("nas", ln), ("cloud", lc), ("ops", lo))}
has_new = any(new_in.values())
if has_new:
    if not all(len(v) == 1 for v in new_in.values()):
        errors.append("the new key must appear exactly once in nas, cloud and ops")
    elif len({new_in[n][0] for n in new_in}) != 1:
        errors.append("the new key's line is not the same string in nas, cloud and ops")
    else:
        line = new_in["ops"][0]
        m = re.fullmatch(r'from="([^"]+)"\s+ssh-ed25519\s+\S+\s+semaphore-automation@ops\.de\.wahlberger\.dev', line)
        if not m:
            errors.append('the new key must be `from="..." ssh-ed25519 <key> semaphore-automation@ops.de.wahlberger.dev` with no other option')
        else:
            addrs = m.group(1).split(",")
            try:
                [ipaddress.ip_network(a, strict=False) for a in addrs]
            except ValueError:
                errors.append("a from= entry is not an IP address or CIDR")
            for need, name in ((vo.get("vm_zt_ip"), "vm_zt_ip"), (vo.get("semaphore_network_subnet"), "semaphore_network_subnet"),
                               (os.environ.get("VM_PUBLIC_IP"), "VM_PUBLIC_IP")):
                if name != "VM_PUBLIC_IP" and not need:
                    errors.append(f"{name} is empty but the new key is present (set it before PR C)")
                elif need and need not in addrs:
                    errors.append(f"from= lacks {name}")
            if len(addrs) < 3 or len(set(addrs)) != len(addrs):
                errors.append("from= must list <vm-public-ip>, <vm-zt-ip>, <sem-subnet> (+ extras), without duplicates")
if stage == "E":
    if not has_new:
        errors.append("stage E: the new key must be in the lists")
    exp_nas, exp_ops = ["new", "personal"], ["new", "personal"]
elif has_new:
    exp_nas, exp_ops = ["new", "old", "personal"], ["new", "personal"]
else:
    exp_nas, exp_ops = ["old", "personal"], ["personal"]
if kinds(ln) != exp_nas:
    errors.append(f"nas/cloud list holds {kinds(ln)}, SH-BR-10 expects {exp_nas}")
if kinds(lo) != exp_ops:
    errors.append(f"ops list holds {kinds(lo)}, SH-BR-10 expects {exp_ops}")
if errors:
    sys.exit("\n".join(errors))
PY
    # The literal spec grep, over tracked + untracked files. The planning
    # documents quote the words, this script builds the pattern from pieces.
    pat="PRIVATE"" KEY"
    g=$(cd "$repo" && git grep --untracked -n -I -e "$pat" -- . ':(exclude)semaphore-migration' ':(exclude)*/tests/static-checks.sh' ':(exclude)*/tests/unit/*') \
        && { echo "private key material in the repository:"; printf '%s\n' "$g" | cut -d: -f1,2; rc=1; }
    return $rc
}

# --- SH-AC-27 (+ SH-FR-70, 90, 96, 133, 134): README content ------------------
ac27() {
    python3 - <<'PY'
import os, re, sys

path = os.path.join(os.environ["SC_OPS"], "README.md")
try:
    text = open(path).read()
except OSError:
    sys.exit("README.md missing")
errors = []
lines = text.splitlines()

def section(step):
    """Text of the heading mentioning `Step <step>` up to the next heading of the same or higher level."""
    for i, l in enumerate(lines):
        m = re.match(r"(#+)\s.*\bStep " + str(step) + r"\b(?!\.)", l, re.I)
        if m:
            level = len(m.group(1))
            body = []
            for l2 in lines[i + 1:]:
                m2 = re.match(r"(#+)\s", l2)
                if m2 and len(m2.group(1)) <= level:
                    break
                body.append(l2)
            return "\n".join(body)
    return None

for s in range(10):
    body = section(s)
    if body is None:
        errors.append(f"no heading for Step {s}")
        continue
    if not re.search(r"SH-AC-\d+", body):
        errors.append(f"Step {s}: no gate scenario (SH-AC-nn)")
    if not re.search(r"rollback", body, re.I):
        errors.append(f"Step {s}: no rollback")
for pr in ("A", "A2", "A3", "B", "B2", "C", "C2", "C-R", "D", "E"):
    if not re.search(r"^\|\s*" + re.escape(pr) + r"\s*\|", text, re.M):
        errors.append(f"PR table lacks a row for {pr}")
need = [
    (r"semaphore_image", "the semaphore_image note"),
    (r"-e ansible_host=ops\.de\.int\.wahlberger\.dev", "the -e ansible_host=ops.de.int.wahlberger.dev hint"),
    (r"^#+\s.*restor", "a database restore heading"),
    (r"^#+\s.*cloud firewall", "a Cloud Firewall heading"),
    (r"hcloud firewall", "hcloud firewall commands"),
    (r"^#+\s.*break[- ]glass", "a break-glass heading"),
]
for pat, what in need:
    if not re.search(pat, text, re.I | re.M):
        errors.append(f"README lacks {what}")
if errors:
    sys.exit("\n".join(errors))
PY
}

# --- SH-AC-30 (source level): restic timer, script and excludes ---------------
# The templates are parameterised, so the EFFECTIVE values (role default,
# overridden by the production vars.yml) are checked together with the template
# text. SH-AC-30r renders them for real.
ac30() {
    python3 - <<'PY'
import os, re, sys, yaml

ops = os.environ["SC_OPS"]
role = f"{ops}/roles/restic_backup"
errors = []
def read(path):
    try:
        return open(path).read()
    except OSError:
        errors.append(f"{os.path.relpath(path, ops)} missing")
        return ""
eff = {}
for f in (f"{role}/defaults/main.yml", f"{ops}/inventories/production/group_vars/all/vars.yml"):
    eff.update(yaml.safe_load(read(f)) or {})
timer, script, env = (read(f"{role}/templates/{n}") for n in ("restic-backup.timer.j2", "restic-backup.sh.j2", "restic-backup.env.j2"))
if "OnCalendar={{ restic_backup_on_calendar }}" not in timer or eff.get("restic_backup_on_calendar") != "*-*-* 05:00:00":
    errors.append("timer must render OnCalendar=*-*-* 05:00:00")
if not re.search(r"^Persistent=true$", timer, re.M):
    errors.append("timer lacks Persistent=true")
if re.search(r"forget|prune", script):
    errors.append("restic-backup.sh.j2 mentions forget or prune (SH-FR-81, comments included)")
if len(re.findall(r"restic check", script)) != 1 or "restic check --read-data-subset={{ restic_backup_check_read_data_subset }}" not in script \
        or eff.get("restic_backup_check_read_data_subset") != "10%":
    errors.append("script must hold exactly one `restic check --read-data-subset=10%`")
if "--exclude {{ path | quote }}" not in script:
    errors.append("script no longer renders restic_backup_exclude as --exclude arguments")
for ex in ("config.json", "*.env", "identity.secret"):
    if ex not in (eff.get("restic_backup_exclude") or []):
        errors.append(f"restic_backup_exclude lacks {ex} (SH-FR-80/151/171)")
if not re.search(r"^RESTIC_REPOSITORY=rest:http://\{\{ restic_backup_rest_server_username \}\}:", env, re.M) \
        or (eff.get("restic_backup_rest_server_host"), eff.get("restic_backup_rest_server_port"), eff.get("restic_backup_rest_server_username")) \
        != ("nas.de.int.wahlberger.dev", 8000, "ops"):
    errors.append("repository URL must be rest:http://ops:...@nas.de.int.wahlberger.dev:8000/ops/")
if errors:
    sys.exit("\n".join(errors))
PY
}

# --- SH-AC-30r: the rendered templates (render-check.sh, Docker/Podman) -------
ac30r() {
    [ "${STATIC_CHECKS_SKIP_RENDER:-}" != 1 ] || { echo "STATIC_CHECKS_SKIP_RENDER=1 (run tests/render-check.sh separately)"; return 77; }
    run_step "render-check" "$ops_dir" tests/render-check.sh
}

# --- SH-AC-43 (+ SH-FR-111, 160, 161): the repository is clean after PR E -----
ac43() {
    [ "$stage" = E ] || { echo "applies after pull request E; run with STATIC_CHECKS_STAGE=E"; return 77; }
    rc=0
    [ ! -e "$repo/$pi_rel" ] || { echo "$pi_rel/ still exists"; rc=1; }
    # FR-111 allowlist: */reqs/*, */PLAN*.md, dated notes in architecture/ and
    # homelab-architecture/, the NAS README (DOC-O5), the VM README (runbook).
    # Assumption: the planning directory and this playbook's own test harness
    # (which names the Pi directory in its guards) are allowed as well.
    g=$(cd "$repo" && git grep --untracked -n -I -e 'pi\.de\.int\.wahlberger\.dev' -e 'pi-de-int-wahlberger-dev' -- . \
        ':(exclude,glob)**/reqs/**' ':(exclude,glob)**/PLAN*.md' ':(exclude)architecture' ':(exclude)homelab-architecture' \
        ':(exclude)nas-de-int-wahlberger-dev/README.md' ":(exclude)$ops_rel/README.md" ':(exclude)semaphore-migration' \
        ":(exclude)$ops_rel/tests") && { echo "references outside the SH-FR-111 allowlist:"; printf '%s\n' "$g" | cut -d: -f1,2; rc=1; }
    return $rc
}

# --- SH-AC-44 (static half): revoked-keys input declared in all three roles ---
ac44() {
    python3 - <<'PY'
import os, sys, yaml

errors = []
for label, d in (("nas", os.environ["SC_NAS"]), ("cloud", os.environ["SC_CLOUD"]), ("ops", os.environ["SC_OPS"])):
    role = f"{d}/roles/ssh_authorized_keys"
    try:
        specs = yaml.safe_load(open(f"{role}/meta/argument_specs.yml"))["argument_specs"]
        opt = specs["main"]["options"]["ssh_authorized_keys_revoked"]
        if opt.get("type") != "list" or opt.get("elements") != "str" or opt.get("default") != []:
            errors.append(f"{label}: ssh_authorized_keys_revoked must be list of str with default []")
        if not opt.get("description"):
            errors.append(f"{label}: ssh_authorized_keys_revoked lacks a description")
        defaults = yaml.safe_load(open(f"{role}/defaults/main.yml")) or {}
        if defaults.get("ssh_authorized_keys_revoked") != []:
            errors.append(f"{label}: defaults/main.yml must set ssh_authorized_keys_revoked: []")
    except (OSError, KeyError, TypeError, yaml.YAMLError) as e:
        errors.append(f"{label}: argument_specs/defaults unreadable ({type(e).__name__})")
if not os.path.isfile(f"{os.environ['SC_OPS']}/molecule/default/verify-ssh-keys.yml"):
    errors.append("ops molecule/default/verify-ssh-keys.yml missing (the three converges)")
if errors:
    sys.exit("\n".join(errors))
PY
    rc=$?
    # The role is a copy per playbook (repository convention): the code must not
    # drift. meta/main.yml (platforms) and README.md legitimately differ.
    for other in "$nas_dir" "$cloud_dir"; do
        for part in tasks vars defaults meta/argument_specs.yml; do
            a="$other/roles/ssh_authorized_keys/$part"
            b="$ops_dir/roles/ssh_authorized_keys/$part"
            if [ ! -e "$a" ] || [ ! -e "$b" ]; then
                echo "ssh_authorized_keys/$part missing in $(basename "$other") or ops"
                rc=1
            elif ! d=$(diff -r "$a" "$b" 2>&1); then
                echo "ssh_authorized_keys/$part differs between $(basename "$other") and $ops_rel:"
                printf '%s\n' "$d" | head -10 | sed 's/^/    /'
                rc=1
            fi
        done
    done
    return $rc
}

# --- SH-AC-45 (static half): sshd is validated before it is applied -----------
ac45() {
    python3 - <<'PY'
import os, sys, yaml

ops = os.environ["SC_OPS"]
errors = []
WRITERS = ("lineinfile", "blockinfile", "template", "copy")

def walk(tasks):
    for t in tasks or []:
        if not isinstance(t, dict):
            continue
        yield t
        for k in ("block", "rescue", "always"):
            yield from walk(t.get(k))

tasks = yaml.safe_load(open(f"{ops}/roles/security/tasks/sshd.yml")) or []
writers = 0
for t in walk(tasks):
    for mod in WRITERS:
        body = next((t[k] for k in t if k == mod or k.endswith("." + mod)), None)
        if isinstance(body, dict) and "sshd" in str(body.get("dest") or body.get("path") or ""):
            writers += 1
            # A pure line removal (state: absent) cannot add a bad directive.
            if mod in ("lineinfile", "blockinfile") and body.get("state") == "absent":
                continue
            if "sshd -t" not in str(body.get("validate", "")):
                errors.append(f"sshd.yml task '{t.get('name')}': writes sshd config without `validate: sshd -t -f %s`")
if writers == 0:
    errors.append("sshd.yml: found no task that writes an sshd config file")
verify = open(f"{ops}/molecule/default/verify-security.yml").read()
if "SH-AC-45" not in verify:
    errors.append("molecule verify-security.yml has no SH-AC-45 scenario")
if errors:
    sys.exit("\n".join(errors))
PY
}

# --- SH-AC-56 (+ SH-FR-188, 189, 214): self-run safety ------------------------
ac56() {
    python3 - <<'PY'
import glob, os, re, sys, yaml

ops = os.environ["SC_OPS"]
errors = []
# (a) the sshd handler reloads. The grep is scoped to sshd: the ssh-login-notify
# handler legitimately says `restarted`.
handlers = yaml.safe_load(open(f"{ops}/roles/security/handlers/main.yml")) or []
sshd = [h for h in handlers if isinstance(h, dict)
        for m in [next((v for k, v in h.items() if k.split(".")[-1] == "systemd"), None)]
        if isinstance(m, dict) and str(m.get("name")) in ("sshd", "sshd.service", "ssh")]
if not sshd:
    errors.append("security handlers: no sshd handler found")
for h in sshd:
    st = next(v for k, v in h.items() if k.split(".")[-1] == "systemd").get("state")
    if st != "reloaded":
        errors.append(f"security handler '{h.get('name')}' has state {st}, expected reloaded")
for f in glob.glob(f"{ops}/roles/security/tasks/*.yml"):
    for t in yaml.safe_load(open(f)) or []:
        if isinstance(t, dict):
            for k, v in t.items():
                if k.split(".")[-1] == "systemd" and isinstance(v, dict) and str(v.get("name")) in ("sshd", "sshd.service", "ssh") \
                        and v.get("state") in ("restarted", "stopped"):
                    errors.append(f"{os.path.basename(f)}: task '{t.get('name')}' restarts sshd")
# (b) the firewall role never reloads or restarts firewalld (comments excluded).
for root, _, files in os.walk(f"{ops}/roles/firewall"):
    for fn in files:
        if fn.endswith(".md"):
            continue
        p = os.path.join(root, fn)
        for n, l in enumerate(open(p, errors="replace"), 1):
            code = re.sub(r"\s#.*$|^\s*#.*$", "", l)
            if re.search(r"reload|restart", code, re.I):
                errors.append(f"{os.path.relpath(p, ops)}:{n}: firewall role must not reload/restart firewalld")
# (c) the update script has no reboot call but rebootmgrctl.
found = False
for name in ("zypper-dup-request-reboot.sh.j2", "zypper-dup.service.j2"):
    p = f"{ops}/roles/security/templates/{name}"
    try:
        lines = open(p).read().splitlines()
    except OSError:
        errors.append(f"{name} missing")
        continue
    for n, l in enumerate(lines, 1):
        code = re.sub(r"\s#.*$|^\s*#.*$", "", l)
        # Quoted text (echo messages) is not a call.
        code = re.sub(r'"[^"]*"|\'[^\']*\'', '""', code)
        if "rebootmgrctl reboot" in code:
            found = True
        code = code.replace("rebootmgrctl reboot", "")
        code = re.sub(r"reboot-notify[\w./-]*|needs-rebooting|zypper-dup-request-reboot\.sh|security_autoupdate_reboot\w*", "", code)
        if re.search(r"\breboot\b|\bshutdown\b|\bpoweroff\b|\bhalt\b|\bkexec\b", code, re.I):
            errors.append(f"{name}:{n}: reboot call other than `rebootmgrctl reboot`")
if not found:
    errors.append("no `rebootmgrctl reboot` in the update script (its only reboot path)")
if errors:
    sys.exit("\n".join(errors))
PY
}

# --- SH-AC-60 (+ SH-FR-160, 161): Renovate leaves the Pi and the VM image alone
ac60() {
    python3 - <<'PY'
import fnmatch, json, os, sys

repo, stage = os.environ["SC_REPO"], os.environ["SC_STAGE"]
errors = []
try:
    cfg = json.load(open(f"{repo}/renovate.json"))
except (OSError, ValueError) as e:
    sys.exit(f"renovate.json unreadable ({type(e).__name__})")
rules = [r for r in cfg.get("packageRules", []) if r.get("enabled") is False]

def covers(path):
    for r in rules:
        pats = r.get("matchFileNames") or r.get("matchPaths") or r.get("includePaths") or []
        if any(fnmatch.fnmatchcase(path, p) for p in pats):
            return True
    return False

pi = "pi-de-int-wahlberger-dev/roles/semaphore/defaults/main.yml"
vm = "ops-de-wahlberger-dev/roles/semaphore/defaults/main.yml"
want_pi = stage in ("A", "D")      # FR-160: from PR A until PR E
want_vm = stage == "A"             # FR-161: from PR A until PR D
for path, want, what in ((pi, want_pi, "FR-160 (Pi directory)"), (vm, want_vm, "FR-161 (VM semaphore defaults)")):
    if covers(path) != want:
        errors.append(f"stage {stage}: renovate.json {'lacks' if want else 'still has'} the enabled:false rule of SH-{what}")
if errors:
    sys.exit("\n".join(errors))
PY
}

# --- SH-AC-62: the two guard tests, each in its own run (PA-6) ----------------
ac62a() { run_step "guard cloudflare_dns" "$ops_dir" tests/guard-tests.sh cloudflare_dns; }
ac62b() { run_step "guard caddy" "$ops_dir" tests/guard-tests.sh caddy; }
# T-16 defect 1 (R6 / OP-02): the ZeroTier-zone tasks stay gated for the first --check.
fwgate() { run_step "guard firewall" "$ops_dir" tests/guard-tests.sh firewall; }

# --- SH-GUARDS: every other guard in tests/guards.d, one run each --------------
# cloudflare_dns, caddy and firewall have their own ids above (SH-AC-62a/b,
# SH-R6); every other file is run here, so a new guard is wired by existing.
# Guards that need Docker/Podman (and some the network) are SH-GUARDS-C.
own_id_guards=" cloudflare_dns caddy firewall "
container_guards=" restic_backup security_check_mode semaphore "
run_guards() { # <offline|container>
    want=$1 rc=0 n=0
    for g in $("$ops_dir/tests/guard-tests.sh" --list); do
        case "$own_id_guards" in *" $g "*) continue ;; esac
        case "$container_guards" in *" $g "*) [ "$want" = container ] || continue ;; *) [ "$want" = offline ] || continue ;; esac
        n=$((n + 1))
        run_step "guard $g" "$ops_dir" tests/guard-tests.sh "$g" || rc=1
    done
    [ "$n" -gt 0 ] || { echo "no $want guards found in tests/guards.d"; return 1; }
    return $rc
}
guards_offline() { run_guards offline; }
guards_container() {
    [ "${STATIC_CHECKS_SKIP_CONTAINER_GUARDS:-}" != 1 ] || { echo "STATIC_CHECKS_SKIP_CONTAINER_GUARDS=1"; return 77; }
    if ! { { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; } \
        || { command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; }; }; then
        echo "no running Docker/Podman"
        return 77
    fi
    run_guards container
}

# --- SH-AC-63 (static part): vm_zt_ip / vm_zt_iface and the flow-rule record ---
ac63() {
    python3 - <<'PY'
import ipaddress, os, re, sys, yaml

ops = os.environ["SC_OPS"]
errors = []
v = yaml.safe_load(open(f"{ops}/inventories/production/group_vars/all/vars.yml"))
ip, iface = v.get("vm_zt_ip", ""), v.get("vm_zt_iface", "")
if ip not in ("", None):
    try:
        a = ipaddress.IPv4Address(str(ip))
        if a not in ipaddress.ip_network("10.243.0.0/16"):
            errors.append("vm_zt_ip is not in 10.243.0.0/16")
    except ValueError:
        errors.append("vm_zt_ip is not an IPv4 address")
if bool(ip) != bool(iface):
    errors.append("vm_zt_ip and vm_zt_iface must be set together (PR A2) or both empty (PR A)")
if iface and not re.fullmatch(r"[A-Za-z0-9_.-]+", str(iface)):
    errors.append("vm_zt_iface is not an interface name")
try:
    doc = open(f"{ops}/docs/zerotier-flow-rules.md").read()
    if not re.search(r"before", doc, re.I):
        errors.append('docs/zerotier-flow-rules.md lacks the "before" rule set')
    if ip and not re.search(r"in force", doc, re.I):
        errors.append('vm_zt_ip is set but docs/zerotier-flow-rules.md lacks the dated "in force" rule set')
except OSError:
    errors.append("docs/zerotier-flow-rules.md missing")
if errors:
    sys.exit("\n".join(errors))
PY
}

# --- SH-FR-97: the Pi directory is not changed until step 7 ends --------------
fr97() {
    [ "${STEP7_DONE:-0}" != 1 ] || { echo "STEP7_DONE=1 (step 7 ended)"; return 77; }
    rc=0
    a=$(git -C "$repo" diff --name-only --no-renames "$base" -- "$pi_rel"; git -C "$repo" ls-files --others --exclude-standard -- "$pi_rel";
        git -C "$repo" log --format= --name-only --no-renames "$base"..HEAD -- "$pi_rel")
    [ -z "$a" ] || { echo "$pi_rel changed against $(git -C "$repo" rev-parse --short "$base"):"; printf '%s\n' "$a" | sort -u | head; rc=1; }
    return $rc
}

# --- SH-FR-205: no ZeroTier Central API token in the repository ---------------
# Markdown files are excluded: role READMEs explain in prose that no token is
# used (the spec's bare grep matches that sentence); assignments in .md files
# are still searched below.
fr205() {
    rc=0
    g=$(cd "$repo" && git grep --untracked -n -I -i -e 'zerotier.*token' -e 'ZT_TOKEN' -- . \
        ':(exclude,glob)**/*.md' ':(exclude)semaphore-migration' ':(exclude)*/tests/static-checks.sh' ':(exclude)*/tests/unit/*') \
        && { echo "possible ZeroTier token:"; printf '%s\n' "$g" | cut -d: -f1,2; rc=1; }
    m=$(cd "$repo" && git grep --untracked -n -I -i -E -e '(zt_token|zerotier[a-z_]*token)[[:space:]]*[:=]' -- '*.md' ':(exclude)semaphore-migration') \
        && { echo "token assignment in a document:"; printf '%s\n' "$m" | cut -d: -f1,2; rc=1; }
    return $rc
}

# --- SH-BR-16: PR boundary (opt-in; it is a diff check for a PR branch) -------
br16() {
    [ -n "${STATIC_CHECKS_PR:-}" ] || { echo "set STATIC_CHECKS_PR=<A|A2|...> on a PR branch (tests/pr-boundaries.sh)"; return 77; }
    run_step "pr-boundaries" "$ops_dir" tests/pr-boundaries.sh "$STATIC_CHECKS_PR"
}

# --- pytest tests/unit (the negative tests of this script) --------------------
unit() {
    [ "${STATIC_CHECKS_SKIP_UNIT:-}" != 1 ] || { echo "STATIC_CHECKS_SKIP_UNIT=1"; return 77; }
    command -v "${pytest_cmd[0]}" >/dev/null 2>&1 || { echo "no pytest (set PYTEST=\"pipx run pytest\")"; return 77; }
    run_step "pytest" "$ops_dir" env STATIC_CHECKS_SKIP_UNIT=1 "${pytest_cmd[@]}" tests/unit -q
}

echo "static checks (stage $stage), diff base: $(git -C "$repo" rev-parse --short "$base")"
check SH-AC-01 "skeleton: roles/tags, inventory, files, personal key (FR-13, 143, 62)" ac01
check SH-AC-01L "yamllint, ansible-lint, syntax-check" ac01l
check SH-AC-17 "vars wiring and vault.yml.example" ac17
check SH-AC-17v "decrypted vault keys (PyYAML + Ansible loader)" ac17v
check SH-AC-23 "key lists per BR-10, from= option, no private key" ac23
check SH-AC-27 "README content" ac27
check SH-AC-30 "restic timer/script/excludes (source)" ac30
check SH-AC-30r "restic templates rendered (render-check.sh)" ac30r
check SH-AC-43 "repository clean after PR E (FR-111, 160, 161)" ac43
check SH-AC-44 "revoked-keys input declared, ssh_authorized_keys identical in nas/cloud/ops" ac44
check SH-AC-45 "sshd validated before apply" ac45
check SH-AC-56 "handler reloads, firewall never reloads, only rebootmgrctl reboots" ac56
check SH-AC-60 "Renovate freeze rules for the stage" ac60
check SH-AC-62a "guard test cloudflare_dns (own run)" ac62a
check SH-AC-62b "guard test caddy (own run)" ac62b
check SH-R6 "guard test firewall (zone tasks gated for first --check)" fwgate
check SH-GUARDS "all other offline guards in tests/guards.d (vm_vars, podman, regexes, ...)" guards_offline
check SH-GUARDS-C "container guards in tests/guards.d (restic_backup, semaphore, security_check_mode)" guards_container
check SH-AC-63 "vm_zt_ip/vm_zt_iface and flow-rule record" ac63
check SH-FR-97 "pi-de-int-wahlberger-dev untouched until step 7" fr97
check SH-FR-205 "no ZeroTier Central token" fr205
check SH-BR-16 "PR boundary (STATIC_CHECKS_PR)" br16
check UNIT "pytest tests/unit" unit

if [ "$fails" -gt 0 ]; then
    echo "static checks: $fails FAILED"
    exit 1
fi
echo "static checks: all passed (SKIPPED lines are not passes)"
