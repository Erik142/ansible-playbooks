#!/usr/bin/env bash
# Guest-side helpers for V3 (T-18). Sourced as root in the VM by garage-v3-run.sh. Fake VM key only.
# shellcheck shell=bash
AWS_IMAGE=docker.io/amazon/aws-cli:2.38.1
W=/var/tmp/g3/w; mkdir -p "$W"
G() { podman exec garage /garage "$@" 2>/dev/null; }
creds() {
  local info; info=$(G key info --show-secret test-rw)
  AKID=$(awk -F': *' '/^Key ID/{print $2; exit}' <<<"$info"); SEC=$(awk -F': *' '/^Secret key/{print $2; exit}' <<<"$info")
}
s3() { podman run --rm --network systemd-garage -v "$W":/w:Z \
  -e AWS_ACCESS_KEY_ID="$AKID" -e AWS_SECRET_ACCESS_KEY="$SEC" -e AWS_DEFAULT_REGION=garage \
  -e AWS_EC2_METADATA_DISABLED=true "$AWS_IMAGE" --endpoint-url http://garage:3900 s3api "$@"; }
put() { head -c "${3:-65536}" /dev/urandom >"$W/put.$$"; s3 put-object --bucket sstate --key "$1" --body "/w/put.$$" >/dev/null 2>&1 || { rm -f "$W/put.$$"; return 1; }
  sha256sum "$W/put.$$" | cut -d' ' -f1 >"$W/sha.$2"; rm -f "$W/put.$$"; }   # put <key> <tag> [bytes]; sha in $W/sha.<tag>
getsha() { rm -f "$W/out"; if s3 get-object --bucket sstate --key "$1" /w/out >/dev/null 2>"$W/err"; then sha256sum "$W/out" | cut -d' ' -f1; else echo "ERR:$(tr '\n' ' ' <"$W/err" | cut -c1-120)"; fi; }
head404() { s3 head-object --bucket sstate --key "$1" >/dev/null 2>"$W/err"; local rc=$?; [[ $rc -ne 0 ]] && grep -qE '404|Not Found|NoSuchKey' "$W/err"; }
objcount() { G bucket info sstate | awk -F': *' '/^Objects/{print $2; exit}' | awk '{print $1}'; }
load_start() { # three parallel uploaders of 64 KiB objects until $W/run disappears
  touch "$W/run"; podman rm -f garage-load >/dev/null 2>&1
  podman run -d --name garage-load --network systemd-garage -v "$W":/w:Z \
    -e AWS_ACCESS_KEY_ID="$AKID" -e AWS_SECRET_ACCESS_KEY="$SEC" -e AWS_DEFAULT_REGION=garage -e AWS_EC2_METADATA_DISABLED=true \
    --entrypoint sh "$AWS_IMAGE" -c 'for w in 1 2 3; do ( i=0; while [ -f /w/run ]; do i=$((i+1)); head -c 65536 /dev/urandom >/tmp/f$w; aws --endpoint-url http://garage:3900 s3api put-object --bucket sstate --key load/$w-$i --body /tmp/f$w >/dev/null 2>&1; done ) & done; wait' >/dev/null
}
load_stop() { rm -f "$W/run"; podman wait garage-load >/dev/null 2>&1; podman rm -f garage-load >/dev/null 2>&1; true; }
# Restore steps as the README will state them. The backup disk is another btrfs filesystem, so a snapshot
# cannot cross to it: receive both sources into a staging directory on the live filesystems first
# (nothing live is touched if that fails), then stop, move the live subvolumes aside, snapshot the received
# copies (writable) to the live paths. The caller re-renders the secrets (ansible --tags garage) and starts.
restore_stop_replace() { # restore_stop_replace <data-snapshot> <meta-snapshot>
  local sd=/mnt/data/.restore-stage sm=/mnt/containers/.restore-stage
  mkdir -p "$sd" "$sm" || return 1
  btrfs send -q "$1" | btrfs receive -q "$sd" || return 1
  btrfs send -q "$2" | btrfs receive -q "$sm" || return 1
  systemctl stop garage.service || return 1
  mv /mnt/data/garage /mnt/data/garage.pre-restore && mv /mnt/containers/garage/meta /mnt/containers/garage/meta.pre-restore || return 1
  btrfs subvolume snapshot "$sd/$(basename "$1")" /mnt/data/garage >/dev/null || return 1
  btrfs subvolume snapshot "$sm/$(basename "$2")" /mnt/containers/garage/meta >/dev/null || return 1
  btrfs subvolume delete "$sd/$(basename "$1")" "$sm/$(basename "$2")" >/dev/null && rmdir "$sd" "$sm"
}
restore_cleanup() { btrfs subvolume delete /mnt/data/garage.pre-restore /mnt/containers/garage/meta.pre-restore >/dev/null; }
wait_status() { local t0=$SECONDS; while (( SECONDS - t0 < 120 )); do G status >/dev/null 2>&1 && { echo $((SECONDS - t0)); return 0; }; sleep 1; done; echo ">120"; return 1; }
