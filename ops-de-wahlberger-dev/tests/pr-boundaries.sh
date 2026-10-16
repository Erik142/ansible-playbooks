#!/bin/bash
# PR-boundary guard (T-14; SH-BR-16, SH-FR-97): asserts from `git diff` that a
# pull request of the Semaphore-to-Hetzner feature touches only the file
# classes the BR-16 table allows for it, so "safe to apply early" (merge is
# deploy until step 8) and SH-AC-63 are machine-checked.
#
# Usage: tests/pr-boundaries.sh <A|A2|A3|B|B2|C|C2|C-R|D|E>
# Environment:
#   PR_BOUNDARIES_BASE=master  ref to diff against (falls back to origin/<ref>);
#                              the merge-base with HEAD is used
#   STEP7_DONE=1               PR E only: lets it touch pi-de-int-wahlberger-dev/
#                              (SH-FR-97: no commit changes it until step 7 ends)
# The changed set = committed + staged + unstaged changes against the merge-base
# plus untracked, non-ignored files. Renames count as delete + add.
# Exit 0 = inside the boundary; 1 = file outside it (listed) or empty diff;
# 2 = usage / git error.
set -u -f   # -f: the unquoted glob lists below must not expand against the cwd

pr=${1:-}
[ $# -eq 1 ] || { echo "usage: $0 <A|A2|A3|B|B2|C|C2|C-R|D|E>" >&2; exit 2; }

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel) || { echo "pr-boundaries: not in a git repo" >&2; exit 2; }
V=ops-de-wahlberger-dev
N=nas-de-int-wahlberger-dev
C=cloud-wahlberger-dev
PI=pi-de-int-wahlberger-dev

base=${PR_BOUNDARIES_BASE:-master}
if ! git -C "$repo" rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
    base="origin/$base"
fi
base=$(git -C "$repo" merge-base HEAD "$base") || { echo "pr-boundaries: cannot resolve base ref" >&2; exit 2; }

# Allowed glob patterns (bash `case` patterns; `*` also matches `/`) per PR.
keys_vars="$N/inventories/production/group_vars/all/vars.yml $C/inventories/production/group_vars/all/vars.yml $V/inventories/production/group_vars/all/vars.yml"
docs_any='*.md'
case "$pr" in
A)
    allowed="$V/* $N/roles/ssh_authorized_keys/* $C/roles/ssh_authorized_keys/* \
        $C/roles/restic_backup/defaults/main.yml $C/roles/restic_backup/README.md \
        renovate.json .github/workflows/ci.yml semaphore-migration/* architecture/* homelab-architecture/*" ;;
A2 | A3)
    allowed="$V/*" ;;
B)
    allowed="$N/inventories/production/group_vars/all/* $N/tests/static-checks.sh $docs_any" ;;
B2)
    allowed="$N/inventories/production/group_vars/all/* $N/inventories/vm/* $N/roles/restic_server/* $N/tests/* $docs_any" ;;
C | C2 | C-R)
    allowed="$keys_vars" ;;
D)
    allowed="$V/inventories/production/group_vars/all/vars.yml $N/roles/homepage/* renovate.json $docs_any" ;;
E)
    allowed="$N/inventories/production/group_vars/all/vars.yml $C/inventories/production/group_vars/all/vars.yml \
        $N/roles/ssh_authorized_keys/* $C/roles/ssh_authorized_keys/* $V/inventories/production/group_vars/all/vars.yml \
        renovate.json .github/* $docs_any"
    [ "${STEP7_DONE:-0}" = 1 ] && allowed="$allowed $PI/*" ;;
*)
    echo "usage: $0 <A|A2|A3|B|B2|C|C2|C-R|D|E>   (got '$pr')" >&2
    exit 2 ;;
esac

changed=$( {
    git -C "$repo" diff --name-only --no-renames "$base" || exit 2
    git -C "$repo" ls-files --others --exclude-standard
} | sort -u )
[ -n "$changed" ] || { echo "pr-boundaries $pr: FAIL - no changed files against $(git -C "$repo" rev-parse --short "$base")"; exit 1; }

bad=""
while IFS= read -r f; do
    # SH-FR-97: the Pi directory is frozen for every PR; E may touch it only
    # after step 7 (STEP7_DONE=1, handled in `allowed`). Checked before the
    # *.md allowance so a Pi README cannot slip through as documentation.
    case "$f" in
    "$PI"/*)
        if [ "$pr" = E ] && [ "${STEP7_DONE:-0}" = 1 ]; then continue; fi
        bad="$bad$f  (pi directory is frozen until step 7 ends, SH-FR-97)
"
        continue ;;
    esac
    ok=0
    for pat in $allowed; do
        # shellcheck disable=SC2254  # the unquoted pattern is the point
        case "$f" in $pat) ok=1; break ;; esac
    done
    [ $ok = 1 ] || bad="$bad$f
"
done <<<"$changed"

# PR A2 is defined by two files (SH-AC-63): the IP/interface variables and the
# dated "in force" flow-rule record.
if [ "$pr" = A2 ]; then
    for need in "$V/inventories/production/group_vars/all/vars.yml" "$V/docs/zerotier-flow-rules.md"; do
        printf '%s\n' "$changed" | grep -qxF "$need" || bad="$bad$need  (PR A2 must change this file)
"
    done
fi

if [ -n "$bad" ]; then
    echo "pr-boundaries $pr: FAIL - outside the BR-16 boundary:"
    printf '%s' "$bad" | sed 's/^/    /'
    exit 1
fi
echo "pr-boundaries $pr: OK ($(printf '%s\n' "$changed" | wc -l | tr -d ' ') changed file(s))"
