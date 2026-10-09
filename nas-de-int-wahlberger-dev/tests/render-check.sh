#!/bin/sh
# Render check (BD-FR-154): renders the templates registered in tests/render.d/
# with the VM fixture overrides, then verifies them inside a disposable
# openSUSE Tumbleweed container (`btrbk config print`, `systemd-analyze verify`).
# Needs Docker or Podman and network access; touches no host (BD-C-03).
#
# Usage: tests/render-check.sh [-e key=value ...]
#   -e   extra variable for the render step (repeatable); wins over the fixture.
# Environment: RENDER_CHECK_RUNTIME=docker|podman forces the container runtime,
#              RENDER_CHECK_IMAGE overrides the image.
set -eu

nas_dir=$(cd "$(dirname "$0")/.." && pwd)
image="${RENDER_CHECK_IMAGE:-docker.io/opensuse/tumbleweed:latest}"

extra_args=""
while [ $# -gt 0 ]; do
    case "$1" in
    -e)
        [ $# -ge 2 ] || { echo "render-check: -e needs key=value" >&2; exit 2; }
        # Each pair is passed to ansible as one argv element below.
        extra_args="${extra_args}${extra_args:+
}$2"
        shift 2 ;;
    *) echo "usage: $0 [-e key=value ...]" >&2; exit 2 ;;
    esac
done

pick_runtime() {
    if [ -n "${RENDER_CHECK_RUNTIME:-}" ]; then echo "$RENDER_CHECK_RUNTIME"; return; fi
    for rt in docker podman; do
        if command -v "$rt" >/dev/null 2>&1 && "$rt" info >/dev/null 2>&1; then echo "$rt"; return; fi
    done
    return 1
}
runtime=$(pick_runtime) || { echo "render-check: no working docker or podman found" >&2; exit 2; }
command -v ansible-playbook >/dev/null 2>&1 || { echo "render-check: ansible-playbook not on PATH" >&2; exit 2; }

workdir=$(mktemp -d "${TMPDIR:-/tmp}/render-check.XXXXXX")
trap 'rm -rf "$workdir"' EXIT INT TERM

# A private ansible.cfg keeps the repo's vault_password_file (1Password) and
# fact cache out of this run: the fixture needs neither.
cat >"$workdir/ansible.cfg" <<CFG
[defaults]
inventory = /dev/null
retry_files_enabled = false
localhost_warning = false
CFG

run_ansible() { # $1 = tag
    set -- --tags "$1"
    old_ifs=$IFS
    IFS='
'
    for pair in $extra_args; do set -- "$@" -e "$pair"; done
    IFS=$old_ifs
    ANSIBLE_CONFIG="$workdir/ansible.cfg" ansible-playbook "$@" \
        -e "render_check_nas_dir=$nas_dir" -e "render_check_workdir=$workdir" \
        "$nas_dir/tests/lib/render.yml"
}

echo "== render ($runtime)"
run_ansible render

echo "== verify in $image"
status=0
"$runtime" run --rm -v "$workdir:/work" -v "$nas_dir/tests/lib/container-verify.sh:/verify.sh:ro" \
    "$image" sh /verify.sh || status=$?
if [ "$status" -ne 0 ]; then
    echo "render-check: FAILED (container stage exit $status)" >&2
    exit 1
fi

echo "== assert"
run_ansible assert || { echo "render-check: FAILED (assertions)" >&2; exit 1; }
echo "render-check: OK"
