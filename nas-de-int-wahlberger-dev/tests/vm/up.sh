#!/usr/bin/env bash
# Bring the disposable fixture VM up. Idempotent: every step is skipped when its
# result already exists. See README.md. Never touches nas, cloud or pi.
#
#   FIXTURE_VM_DIR=/path/for/big/files ./up.sh        (default ~/.cache/nas-fixture-vm)
#   ./up.sh --reprovision                              (rerun the guest provisioning only)
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPROVISION=0
[[ "${1:-}" == "--reprovision" ]] && REPROVISION=1

mkdir -p "$FIXTURE_VM_DIR"
for t in "$QEMU" "$QEMU_IMG" "$FW_CODE"; do
  [[ -e "$t" ]] || { echo "missing $t (brew install qemu)" >&2; exit 1; }
done

# Throwaway ssh key (never a real key).
[[ -f "$KEY" ]] || ssh-keygen -q -t ed25519 -N '' -C fixture-throwaway -f "$KEY"
[[ -f "$VARS" ]] || dd if=/dev/zero of="$VARS" bs=1m count=64 2>/dev/null

# --- Stage 1: build the Tumbleweed btrfs-root base image (once) --------------
# No Tumbleweed aarch64 cloud/JeOS image is published, so a Leap 16.0 cloud
# image is booted only to debootstrap-style install Tumbleweed (zypper --root)
# onto a blank disk. The result (tw-base.qcow2) is cached.
if [[ ! -f "$TW_BASE" ]]; then
  vm_running && { echo "a VM is running; run down.sh first" >&2; exit 1; }
  if [[ ! -f "$BASE_IMG" ]]; then
    echo ">> downloading $IMG_URL"
    curl -fL --retry 3 -o "$BASE_IMG.part" "$IMG_URL"
    expected="$(curl -fsL "$IMG_URL.sha256" | awk '{print $1}')"
    actual="$(shasum -a 256 "$BASE_IMG.part" | awk '{print $1}')"
    [[ -n "$expected" && "$expected" == "$actual" ]] || { echo "sha256 mismatch ($expected vs $actual)" >&2; rm -f "$BASE_IMG.part"; exit 1; }
    mv "$BASE_IMG.part" "$BASE_IMG"
  fi
  if [[ ! -f "$SEED" ]]; then
    tmp="$(mktemp -d)"
    cat >"$tmp/user-data" <<EOF
#cloud-config
hostname: bootstrap
users:
  - name: fixture
    shell: /bin/bash
    lock_passwd: true
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $(cat "$KEY.pub")
ssh_pwauth: false
EOF
    printf 'instance-id: nas-vm-bootstrap-1\nlocal-hostname: bootstrap\n' >"$tmp/meta-data"
    # hdiutil appends ".iso" to the output name.
    hdiutil makehybrid -quiet -iso -joliet -default-volume-name cidata -o "$FIXTURE_VM_DIR/seed" "$tmp"
    rm -rf "$tmp"
  fi
  BOOT="$FIXTURE_VM_DIR/bootstrap.qcow2"
  rm -f "$BOOT" "$TW_BASE.part"
  cp "$BASE_IMG" "$BOOT"
  "$QEMU_IMG" resize -q "$BOOT" 20G
  "$QEMU_IMG" create -q -f qcow2 "$TW_BASE.part" 20G
  echo ">> bootstrap VM: building Tumbleweed root (several minutes)"
  vm_start_bootstrap "$BOOT" "$TW_BASE.part"
  wait_ssh 420
  vm_ssh "sudo -n env TARGET_DEV=/dev/vdb PUBKEY='$(cat "$KEY.pub")' bash -s" \
    <"$TESTS_VM_DIR/build-root.sh" | tee "$FIXTURE_VM_DIR/build-root.log" | tail -5
  grep -q BUILD-ROOT-OK "$FIXTURE_VM_DIR/build-root.log"
  vm_stop
  mv "$TW_BASE.part" "$TW_BASE"
  rm -f "$BOOT"
fi

# --- Stage 2: disks. Created once; never recreated, so state survives --------
FRESH=0
if [[ ! -f "$(disk_path root)" ]]; then
  FRESH=1
  cp "$TW_BASE" "$(disk_path root)"
fi
for d in data containers scratch; do
  [[ -f "$(disk_path "$d")" ]] || "$QEMU_IMG" create -q -f qcow2 "$(disk_path "$d")" 10G
done
# Exactly 20 GiB = 21474836480 bytes (backup_disk_expected_size_bytes); left blank.
[[ -f "$(disk_path backup)" ]] || "$QEMU_IMG" create -q -f qcow2 "$(disk_path backup)" 21474836480

# --- Stage 3: boot and wait ----------------------------------------------------
vm_start
echo ">> waiting for ssh"
wait_ssh 420

# --- Stage 4: provision fixtures inside the guest (idempotent) ----------------
if [[ $FRESH -eq 1 || $REPROVISION -eq 1 ]] || ! vm_ssh 'test -f /var/lib/fixture-provisioned'; then
  echo ">> provisioning guest"
  vm_ssh 'sudo -n bash -s' <"$TESTS_VM_DIR/provision-guest.sh" | tee "$FIXTURE_VM_DIR/provision.log" | tail -5
  vm_ssh 'test -f /var/lib/fixture-provisioned' || { echo "provisioning did not complete" >&2; exit 1; }
fi

echo ">> up: ssh -i $KEY -p $SSH_PORT fixture@127.0.0.1"
echo ">> inventory: ansible -i inventories/vm -i tests/vm/inventory.yml nas -m ping"
