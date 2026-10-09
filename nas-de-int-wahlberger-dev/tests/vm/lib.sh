#!/usr/bin/env bash
# Shared settings for the disposable VM fixture (see README.md). Sourced, not run.
# shellcheck shell=bash

TESTS_VM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Big files (images, disks, key, pidfile) live OUTSIDE the repo.
: "${FIXTURE_VM_DIR:=${HOME}/.cache/nas-fixture-vm}"
export FIXTURE_VM_DIR
SSH_PORT="${FIXTURE_SSH_PORT:-2222}"
RESTIC_PORT="${FIXTURE_RESTIC_PORT:-8000}"
VM_MEM="${FIXTURE_MEM:-4096}"
VM_CPUS="${FIXTURE_CPUS:-4}"
QEMU_PREFIX="${QEMU_PREFIX:-/opt/homebrew}"
QEMU="${QEMU_PREFIX}/bin/qemu-system-aarch64"
QEMU_IMG="${QEMU_PREFIX}/bin/qemu-img"
FW_CODE="${QEMU_PREFIX}/share/qemu/edk2-aarch64-code.fd"

# Bootstrap image: Leap 16.0 Minimal-VM aarch64 Cloud. No Tumbleweed aarch64
# cloud/JeOS image is published, so up.sh uses this only to install Tumbleweed
# onto a btrfs disk (build-root.sh).
IMG_URL="https://download.opensuse.org/distribution/leap/16.0/appliances/Leap-16.0-Minimal-VM.aarch64-Cloud.qcow2"
BASE_IMG="${FIXTURE_VM_DIR}/base.qcow2"          # Leap bootstrap image
TW_BASE="${FIXTURE_VM_DIR}/tw-base.qcow2"        # built Tumbleweed btrfs-root image

KEY="${FIXTURE_VM_DIR}/id_fixture"
PIDFILE="${FIXTURE_VM_DIR}/qemu.pid"
VARS="${FIXTURE_VM_DIR}/edk2-vars.fd"
SEED="${FIXTURE_VM_DIR}/seed.iso"
CONSOLE_LOG="${FIXTURE_VM_DIR}/console.log"

# name:size (root is cloned from the base image and grown)
DISKS=(root data containers backup scratch)
disk_path() { echo "${FIXTURE_VM_DIR}/fixture-$1.qcow2"; }

SSH_OPTS=(-i "$KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR -o IdentitiesOnly=yes -o ConnectTimeout=5 -o BatchMode=yes)
vm_ssh() { ssh "${SSH_OPTS[@]}" fixture@127.0.0.1 "$@"; }

vm_running() {
  [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

wait_ssh() { # wait_ssh <seconds>
  local i
  for ((i = 0; i < ${1:-300}; i += 3)); do
    vm_ssh true 2>/dev/null && return 0
    sleep 3
  done
  echo "timeout waiting for ssh on 127.0.0.1:${SSH_PORT}" >&2
  return 1
}

# Start qemu headless in the background. Network: user-mode NAT with the
# 192.168.122.0/24 subnet so the fixture's restic_server_allowed_sources match
# (host-forwarded connections arrive from 192.168.122.2).
# Extra qemu arguments (drives) are passed as parameters.
_qemu_common() {
  QEMU_COMMON=(
    -name nas-vm-fixture
    -machine virt,highmem=on -accel hvf -cpu host
    -smp "$VM_CPUS" -m "$VM_MEM"
    -drive "if=pflash,format=raw,readonly=on,file=${FW_CODE}"
    -drive "if=pflash,format=raw,file=${VARS}"
    -netdev "user,id=n0,net=192.168.122.0/24,host=192.168.122.1,dhcpstart=192.168.122.50,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22,hostfwd=tcp:127.0.0.1:${RESTIC_PORT}-:8000"
    -device virtio-net-pci,netdev=n0
    -device virtio-rng-pci
    -display none -serial "file:${CONSOLE_LOG}"
    -pidfile "$PIDFILE" -daemonize
  )
}
_drive() { # _drive <id> <path> <serial> [extra device opts]
  echo -drive "if=none,id=$1,format=qcow2,file=$2" -device "virtio-blk-pci,drive=$1,serial=$3${4:+,$4}"
}

vm_start() {
  vm_running && { echo "VM already running (pid $(cat "$PIDFILE"))"; return 0; }
  _qemu_common
  # shellcheck disable=SC2046
  "$QEMU" "${QEMU_COMMON[@]}" \
    $(_drive root "$(disk_path root)" FIXTUREROOT bootindex=0) \
    $(_drive data "$(disk_path data)" FIXTUREDATA) \
    $(_drive containers "$(disk_path containers)" FIXTURECONTAINERS) \
    $([[ "${FIXTURE_DETACH:-}" == backup ]] || _drive backup "$(disk_path backup)" FIXTUREBACKUP) \
    $(_drive scratch "$(disk_path scratch)" FIXTURESCRATCH)
}

# Bootstrap VM (Leap, cloud-init seed) with one blank target disk (vdb).
vm_start_bootstrap() { # vm_start_bootstrap <bootstrap-root> <target-disk>
  _qemu_common
  # shellcheck disable=SC2046
  "$QEMU" "${QEMU_COMMON[@]}" \
    $(_drive root "$1" BOOTSTRAPROOT bootindex=0) \
    $(_drive target "$2" TWTARGET) \
    -drive "if=none,id=seed,format=raw,readonly=on,file=${SEED}" -device "virtio-blk-pci,drive=seed,serial=CIDATA"
}

# Graceful stop: ACPI powerdown via the guest, then wait; kill as a last resort.
vm_stop() {
  vm_running || { echo "VM not running"; return 0; }
  local pid i
  pid="$(cat "$PIDFILE")"
  vm_ssh 'sudo -n systemctl poweroff' 2>/dev/null || true
  for ((i = 0; i < 60; i++)); do
    kill -0 "$pid" 2>/dev/null || { rm -f "$PIDFILE"; return 0; }
    sleep 2
  done
  echo "guest did not power off, killing qemu" >&2
  kill "$pid" 2>/dev/null || true
  sleep 2
  rm -f "$PIDFILE"
}
