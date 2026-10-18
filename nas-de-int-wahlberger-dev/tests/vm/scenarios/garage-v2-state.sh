#!/usr/bin/env bash
# Guest helper of VM run V2 (T-17), GS-AC-73. Runs as root in the VM.
#   garage-v2-state.sh set            user sets a 10 MiB quota on private-test and a lifecycle rule on sstate
#   garage-v2-state.sh save <dir>     save the four outputs and the lifecycle configuration
set -uo pipefail
N=systemd-caddy
AWS_IMAGE=docker.io/amazon/aws-cli:2.38.1
G() { podman exec garage /garage "$@" 2>/dev/null; }
info=$(G key info --show-secret test-rw)
akid=$(awk -F': *' '/^Key ID/{print $2; exit}' <<<"$info")
sec=$(awk -F': *' '/^Secret key/{print $2; exit}' <<<"$info")
aws() { podman run --rm --network $N -e AWS_DEFAULT_REGION=garage \
  -e AWS_ACCESS_KEY_ID="$akid" -e AWS_SECRET_ACCESS_KEY="$sec" -e AWS_EC2_METADATA_DISABLED=true \
  "$AWS_IMAGE" --endpoint-url http://garage:3900 "$@"; }
case $1 in
set)
  G bucket set-quotas private-test --max-size 10MiB || exit 1
  aws s3api put-bucket-lifecycle-configuration --bucket sstate --lifecycle-configuration \
    '{"Rules":[{"ID":"expire-tmp","Status":"Enabled","Filter":{"Prefix":"tmp/"},"Expiration":{"Days":30}}]}' || exit 1
  ;;
save)
  d=$2; mkdir -p "$d"
  G layout show >"$d/layout"; G bucket info sstate >"$d/sstate"; G bucket info private-test >"$d/private-test"
  G key info test-rw >"$d/key"
  aws s3api get-bucket-lifecycle-configuration --bucket sstate >"$d/lifecycle" 2>&1
  ;;
esac
