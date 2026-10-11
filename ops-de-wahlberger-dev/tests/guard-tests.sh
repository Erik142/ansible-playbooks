#!/bin/bash
# Runs one guard test of tests/guards.d/ (T-14, PA-6): every guard is its own
# invocation, so `guard-tests.sh cloudflare_dns` and `guard-tests.sh caddy` are
# the two separate runs SH-AC-62 asks for.
#
# Usage: tests/guard-tests.sh <name>     name = tests/guards.d/<name>.yml
#        tests/guard-tests.sh --list     print the available names
# Hermetic: an empty ANSIBLE_CONFIG (so the playbook's ansible.cfg and its
# .vault_pass.sh / 1Password are never used), a throwaway vault password file,
# no inventory but `localhost,`. Exit 0 = guard passed; 1 = guard failed; 2 = usage error.
set -eu

ops_dir=$(cd "$(dirname "$0")/.." && pwd)
guards="$ops_dir/tests/guards.d"

usage() {
    echo "usage: $0 <name> | --list   (names: tests/guards.d/<name>.yml)" >&2
    exit 2
}

[ $# -eq 1 ] || usage
if [ "$1" = "--list" ]; then
    for f in "$guards"/*.yml; do basename "$f" .yml; done
    exit 0
fi

name=$1
# Only a plain file name: no path separators, no leading dot.
case "$name" in
'' | .* | */* | *[!A-Za-z0-9_-]*) echo "guard-tests: invalid guard name '$name'" >&2; usage ;;
esac
[ -f "$guards/$name.yml" ] || { echo "guard-tests: no such guard: $name (try --list)" >&2; exit 2; }
command -v ansible-playbook >/dev/null 2>&1 || { echo "guard-tests: ansible-playbook not on PATH" >&2; exit 2; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/guard-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM
: >"$tmp/ansible.cfg"
echo "guard-tests-throwaway-not-a-secret" >"$tmp/vault-pass"
export ANSIBLE_CONFIG="$tmp/ansible.cfg"
export ANSIBLE_VAULT_PASSWORD_FILE="$tmp/vault-pass"
export ANSIBLE_FORCE_COLOR=0 ANSIBLE_NOCOLOR=1

cd "$ops_dir"
echo "== guard: $name"
# ansible-playbook exits 2 on a failed task, which would collide with this
# script's usage code; any failure is reported as exit 1.
ansible-playbook -i localhost, "tests/guards.d/$name.yml" || { echo "guard-tests: guard '$name' FAILED" >&2; exit 1; }
