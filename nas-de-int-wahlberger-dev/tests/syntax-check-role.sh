#!/bin/sh
# Syntax-checks and lists the tasks of ONE role that site.yml does not wire in
# yet. Builds a throwaway playbook, runs it against the VM fixture inventory,
# never connects to a host.
# Usage: tests/syntax-check-role.sh <role>
set -eu

[ $# -eq 1 ] || { echo "usage: $0 <role>" >&2; exit 2; }
role=$1
nas_dir=$(cd "$(dirname "$0")/.." && pwd)
case "$role" in *[!A-Za-z0-9_]*|"") echo "syntax-check-role: invalid role name '$role'" >&2; exit 2 ;; esac
[ -d "$nas_dir/roles/$role" ] || { echo "syntax-check-role: no such role: roles/$role" >&2; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/syntax-check-role.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

# Private ansible.cfg: no vault script (1Password), roles resolved from the NAS dir.
cat >"$tmp/ansible.cfg" <<CFG
[defaults]
roles_path = $nas_dir/roles
retry_files_enabled = false
CFG
cat >"$tmp/play.yml" <<PLAY
---
- name: Syntax check of role $role
  hosts: nas
  become: true
  roles:
    - role: $role
PLAY

cd "$nas_dir"
export ANSIBLE_CONFIG="$tmp/ansible.cfg"
ansible-playbook -i inventories/vm --syntax-check "$tmp/play.yml"
ansible-playbook -i inventories/vm --list-tasks "$tmp/play.yml"
