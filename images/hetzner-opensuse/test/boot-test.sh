#!/usr/bin/env bash
# Boot a COPY of the built image in qemu (legacy BIOS, like Hetzner) with a cloud-init NoCloud seed
# and probe it over SSH. A pre-upload smoke test; it proves boot, cloud-init user creation, btrfs,
# snapper, root growth and SELinux, NOT Hetzner's datasource, DHCP or NIC naming.
#
#   test/boot-test.sh <image.raw> [outdir] [timeout-seconds]
#
# Needs on a Linux host: qemu-system-x86_64, qemu-img, cloud-localds (cloud-image-utils) or
# genisoimage, ssh, ssh-keygen. KVM is used when /dev/kvm exists, otherwise TCG (slow, allow 20+ min).
# A throwaway SSH key is generated in the output dir; your real key is never used.
set -euo pipefail

DISK="${1:?usage: boot-test.sh <image.raw> [outdir] [timeout-seconds]}"
OUT="${2:-./boot-test-out}"
TMO="${3:-1500}"
PORT="${BOOT_TEST_PORT:-2225}"
USER_NAME=erikwahlberger

for tool in qemu-system-x86_64 qemu-img ssh ssh-keygen; do
  command -v "$tool" >/dev/null || { echo "boot-test: $tool not found" >&2; exit 2; }
done
[ -f "$DISK" ] || { echo "boot-test: $DISK not found" >&2; exit 2; }
case "$DISK" in *.xz) echo "boot-test: pass the uncompressed .raw, not $DISK" >&2; exit 2 ;; esac

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

# Copy, then grow the copy to the Hetzner CX23 disk size so first-boot root growth is exercised.
cp --reflink=auto "$DISK" "$OUT/boot-copy.raw"
qemu-img resize -f raw "$OUT/boot-copy.raw" 40G >/dev/null

rm -f "$OUT/test-key" "$OUT/test-key.pub"
ssh-keygen -q -t ed25519 -N "" -C boot-test -f "$OUT/test-key"

cat >"$OUT/user-data" <<EOF
#cloud-config
users:
  - name: $USER_NAME
    groups: [users]
    shell: /bin/bash
    lock_passwd: true
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $(cat "$OUT/test-key.pub")
ssh_pwauth: false
disable_root: true
EOF
printf 'instance-id: boot-test-%s\nlocal-hostname: ops-boot-test\n' "$(date +%s)" >"$OUT/meta-data"

if command -v cloud-localds >/dev/null; then
  cloud-localds "$OUT/seed.iso" "$OUT/user-data" "$OUT/meta-data"
elif command -v genisoimage >/dev/null; then
  genisoimage -quiet -output "$OUT/seed.iso" -volid cidata -joliet -rock "$OUT/user-data" "$OUT/meta-data"
else
  echo "boot-test: need cloud-localds (cloud-image-utils) or genisoimage" >&2
  exit 2
fi

accel=tcg,thread=multi
[ -r /dev/kvm ] && [ -w /dev/kvm ] && accel=kvm
echo "boot-test: accel=$accel (BIOS boot via default SeaBIOS, no OVMF)"

rm -f "$OUT/qemu.pid" "$OUT/serial.log" "$OUT/monitor.sock"
qemu-system-x86_64 -machine pc -accel "$accel" -m 2048 -smp 2 \
  -drive "file=$OUT/boot-copy.raw,if=virtio,format=raw" \
  -drive "file=$OUT/seed.iso,if=virtio,format=raw,media=cdrom,readonly=on" \
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$PORT-:22" -device virtio-net-pci,netdev=n0 \
  -serial "file:$OUT/serial.log" -display none \
  -monitor "unix:$OUT/monitor.sock,server,nowait" \
  -pidfile "$OUT/qemu.pid" -daemonize
echo "boot-test: qemu pid $(cat "$OUT/qemu.pid") started $(date +%T); serial log $OUT/serial.log"
echo "boot-test: screen capture any time: echo 'screendump $OUT/screen.ppm' | socat - UNIX-CONNECT:$OUT/monitor.sock  (needs socat; convert with: pnmtopng or ImageMagick)"
trap 'kill "$(cat "$OUT/qemu.pid")" 2>/dev/null || true' EXIT

SSH=(ssh -p "$PORT" -i "$OUT/test-key" -o IdentitiesOnly=yes -o BatchMode=yes
     -o PasswordAuthentication=no -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o ConnectTimeout=10 -o LogLevel=ERROR "$USER_NAME@127.0.0.1")

start=$(date +%s)
until "${SSH[@]}" true 2>/dev/null; do
  if [ $(( $(date +%s) - start )) -ge "$TMO" ]; then
    echo "boot-test: TIMEOUT waiting for ssh as $USER_NAME. Last serial output:" >&2
    tail -n 40 "$OUT/serial.log" >&2 || true
    exit 1
  fi
  sleep 10
done
echo "boot-test: ssh answered after $(( $(date +%s) - start )) s"

probe() { printf '\n### %s\n' "$1"; "${SSH[@]}" "$1" 2>&1 || echo "[exit $?]"; }
# shellcheck disable=SC2016
{
  probe 'sudo cloud-init status --wait --long'
  probe 'id; hostname; uptime'
  probe 'sudo -n true && echo SUDO_OK'
  probe 'ls /sys/firmware/efi 2>&1 | head -1; echo "(no such file = booted via BIOS)"'
  probe 'df -h /; lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME,MOUNTPOINTS'
  probe 'findmnt -no FSTYPE,SOURCE,OPTIONS /'
  probe 'sudo btrfs filesystem show /; sudo btrfs subvolume list / | head -20'
  probe 'sudo snapper list-configs; sudo snapper list | head'
  probe 'grep -E "^(PRETTY_NAME|VERSION)=" /etc/os-release; uname -r'
  probe 'getenforce 2>&1; sudo sestatus 2>&1 | head -5; ls /etc/selinux/.autorelabel 2>&1'
  probe 'sudo awk -F: '"'"'$2 !~ /^[!*]/ {print $1}'"'"' /etc/shadow; echo "(accounts with a usable password hash above; none expected)"'
  probe 'sudo sshd -T | grep -iE "^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|authenticationmethods|pubkeyauthentication)"'
  probe 'systemctl --failed --no-legend; systemctl is-active sshd cloud-init cloud-init-local cloud-config cloud-final NetworkManager'
  probe 'systemctl is-enabled jeos-firstboot 2>&1; systemctl is-enabled firewalld 2>&1'
  probe 'ip -br a; ip r'
  probe 'cat /etc/cloud/cloud.cfg.d/90_hetzner.cfg; sudo cloud-id 2>&1'
  probe 'sudo journalctl -b --no-pager -p warning | tail -40'
} >"$OUT/probe.txt"
echo "boot-test: probe written to $OUT/probe.txt"
echo "boot-test: qemu stopped on exit. Review $OUT/probe.txt"
