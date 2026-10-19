#!/usr/bin/env bash
# Test setup for the Garage [V] scenarios (GS-FR-68). Stands in for the user: it
# does what the role README tells the user to do, with the Garage CLI and an S3
# client only. Never in the role, never through role variables. VM only; run after
# the role has deployed Garage. Re-runnable (also after `reset.sh clean`).
set -uo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Everything below runs in the guest as root in one script.
gs "$(cat <<'GUEST'
set -euo pipefail
G() { podman exec garage /garage "$@" 2>/dev/null; }
AWS_IMAGE=docker.io/amazon/aws-cli:2.38.1
K='ab/cd/sstate:pn-foo:x86_64:1.0+git-r0:0123abcd_populate_sysroot.tar.zst'

# 1. Layout (README steps, GS-FR-139): skip when the node already has a role.
if G layout show | grep -q 'No nodes currently have a role'; then
  node=$(G status | awk '/^==== HEALTHY NODES/{h=1;next} h && $1 ~ /^[0-9a-f]{16}$/ {print $1; exit}')
  G layout assign -z dc1 -c 10GiB "$node"
  G layout apply --version 1
fi
G status | grep -q 'NO ROLE ASSIGNED' && { echo "node has no role" >&2; exit 1; }

# 2. Buckets, website access, key, grants (idempotent: create only when missing).
for b in sstate private-test; do
  G bucket info "$b" >/dev/null 2>&1 || G bucket create "$b" >/dev/null
done
G bucket website --allow sstate >/dev/null
G bucket website --deny private-test >/dev/null
G key info test-rw >/dev/null 2>&1 || G key create test-rw >/dev/null
for b in sstate private-test; do
  G bucket allow "$b" --key test-rw --read --write >/dev/null
done

# 3. Objects through the S3 API (path-style, region garage) from a container on garage.network.
info=$(G key info --show-secret test-rw)
akid=$(awk -F': *' '/^Key ID/{print $2; exit}' <<<"$info")
sec=$(awk -F': *' '/^Secret key/{print $2; exit}' <<<"$info")
w=$(mktemp -d)
head -c 1048576 /dev/urandom >"$w/up"
head -c 4096 /dev/urandom >"$w/k"
s3() { podman run --rm --network systemd-garage -v "$w":/w:Z \
  -e AWS_ACCESS_KEY_ID="$akid" -e AWS_SECRET_ACCESS_KEY="$sec" -e AWS_DEFAULT_REGION=garage \
  -e AWS_EC2_METADATA_DISABLED=true "$AWS_IMAGE" --endpoint-url http://garage:3900 s3api "$@"; }
s3 put-object --bucket sstate --key selftest/up --body /w/up >/dev/null
s3 put-object --bucket sstate --key "$K" --body /w/k >/dev/null
sha256sum "$w/up" "$w/k" | sed "s#$w/##" >/var/tmp/garage-test-setup.sha256
rm -rf "$w"
G status | grep -v 'NO ROLE'
G bucket list
GUEST
)"
rc=$?
if [[ $rc -eq 0 ]]; then record garage-test-setup PASS "layout, buckets sstate/private-test, key test-rw, objects selftest/up and K"
else record garage-test-setup FAIL "rc=$rc"; fi
exit $rc
