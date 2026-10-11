#!/bin/sh
# Behaviour test for the restic_backup role (T-11). Renders the REAL backup
# script template twice, then runs it in a disposable openSUSE Tumbleweed
# container against a local throwaway restic repository and a WAL-mode SQLite
# database. Touches no host and no real repository.
#
# Usage: roles/restic_backup/tests/behaviour.sh
# Needs: docker or podman, ansible-playbook on PATH.
# Environment: RENDER_CHECK_RUNTIME, RENDER_CHECK_IMAGE (same as render-check.sh),
#              BEHAVIOUR_CONTAINER_NAME (default t11-restic-behaviour).
set -eu

role_dir=$(cd "$(dirname "$0")/.." && pwd)
image="${RENDER_CHECK_IMAGE:-docker.io/opensuse/tumbleweed:latest}"
name="${BEHAVIOUR_CONTAINER_NAME:-t11-restic-behaviour}"
runtime="${RENDER_CHECK_RUNTIME:-docker}"
command -v ansible-playbook >/dev/null 2>&1 || { echo "behaviour: ansible-playbook not on PATH" >&2; exit 2; }
"$runtime" info >/dev/null 2>&1 || { echo "behaviour: $runtime not usable" >&2; exit 2; }

workdir=$(mktemp -d "${TMPDIR:-/tmp}/restic-behaviour.XXXXXX")
cleanup() {
    "$runtime" rm -f "$name" >/dev/null 2>&1 || true
    rm -rf "$workdir" 2>/dev/null || "$runtime" run --rm -v "$workdir:/work" --entrypoint sh "$image" -c 'rm -rf /work/* /work/.[!.]*' >/dev/null 2>&1 || true
    rm -rf "$workdir"
}
trap cleanup EXIT INT TERM

printf '[defaults]\ninventory = /dev/null\nlocalhost_warning = false\n' >"$workdir/ansible.cfg"
cat >"$workdir/render.yml" <<'YML'
- hosts: localhost
  connection: local
  gather_facts: false
  vars_files: ["{{ role_dir }}/defaults/main.yml"]
  vars:
    restic_backup_repo_password: x
    restic_backup_rest_server_password: x
  tasks:
    - ansible.builtin.template:
        src: "{{ role_dir }}/templates/restic-backup.sh.j2"
        dest: "{{ workdir }}/restic-backup.sh"
        mode: "0755"
    - ansible.builtin.template:
        src: "{{ role_dir }}/templates/restic-backup.sh.j2"
        dest: "{{ workdir }}/restic-backup-wide.sh"
        mode: "0755"
      vars:
        restic_backup_paths: ["{{ restic_backup_staging_dir }}", /opt/podman]
YML
ANSIBLE_CONFIG="$workdir/ansible.cfg" ansible-playbook "$workdir/render.yml" \
    -e "role_dir=$role_dir" -e "workdir=$workdir" >/dev/null

"$runtime" rm -f "$name" >/dev/null 2>&1 || true
"$runtime" run --rm --name "$name" -v "$workdir:/work" \
    -v "$role_dir/tests/container-run.sh:/container-run.sh:ro" "$image" sh /container-run.sh
echo "behaviour: OK"
