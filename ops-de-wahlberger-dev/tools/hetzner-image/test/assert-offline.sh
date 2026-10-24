#!/usr/bin/env bash
# Offline assertions on a disk produced by build-in-rescue.sh (container test).
# Usage: assert-offline.sh /dev/loopN <pubkey-file>
set -euo pipefail
DISK="${1:?disk}"; PUB="${2:?pubkey}"
part="${DISK}p3"
fail=0
ok() { printf 'PASS  %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fail=1; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

M="$(mktemp -d)"
trap 'umount -R "$M" 2>/dev/null || true; rmdir "$M" 2>/dev/null || true' EXIT
mount -t btrfs "$part" "$M"
mount -t btrfs -o subvol=@/home "$part" "$M/home"
mount -t btrfs -o subvol=@/var "$part" "$M/var"

sgdisk -p "$DISK" | tail -n 5
check "GPT valid, backup header at end of disk" bash -c "sgdisk -v '$DISK' | grep -q 'No problems found'"
last_usable="$(sgdisk -p "$DISK" | awk '/last usable sector/ {print $NF}')"
p3_end="$(sgdisk -i 3 "$DISK" | awk -F': ' '/^Last sector/ {split($2,a," "); print a[1]}')"
check "partition 3 ends at last usable sector ($p3_end == $last_usable)" [ "$p3_end" = "$last_usable" ]
sz="$(blockdev --getsize64 "$part")"
check "root partition >= 39 GB ($sz)" [ "$sz" -gt 39000000000 ]
fs_size="$(btrfs filesystem show "$M" | awk '/devid/ {print $4}')"
echo "btrfs devid size: $fs_size"
check "btrfs grown (>= 39GiB)" bash -c "[[ '$fs_size' == 39.* || '$fs_size' == 4* ]]"
check "mode/owner .ssh 700 1000:100" [ "$(stat -c '%a %u:%g' "$M/home/erikwahlberger/.ssh")" = "700 1000:100" ]
check "mode/owner authorized_keys 600 1000:100" [ "$(stat -c '%a %u:%g' "$M/home/erikwahlberger/.ssh/authorized_keys")" = "600 1000:100" ]
check "authorized_keys == pubkey, one line" [ "$(cat "$M/home/erikwahlberger/.ssh/authorized_keys")" = "$(cat "$PUB")" ]
check "home 700 1000:100" [ "$(stat -c '%a %u:%g' "$M/home/erikwahlberger")" = "700 1000:100" ]
check "sudoers 440 root:root" [ "$(stat -c '%a %u:%g' "$M/etc/sudoers.d/erikwahlberger")" = "440 0:0" ]
check "sudoers content" [ "$(cat "$M/etc/sudoers.d/erikwahlberger")" = "erikwahlberger ALL=(ALL) NOPASSWD:ALL" ]
check "passwd line" grep -qx 'erikwahlberger:x:1000:100:erikwahlberger:/home/erikwahlberger:/bin/bash' "$M/etc/passwd"
check "shadow: erikwahlberger locked" grep -q '^erikwahlberger:\*:' "$M/etc/shadow"
check "shadow: root locked" grep -qE '^root:[!*]' "$M/etc/shadow"
check "shadow: no usable hash" bash -c "! awk -F: '\$2 !~ /^[!*]/' '$M/etc/shadow' | grep -q ."
check "shadow keeps root:kmem 640" [ "$(stat -c '%a %U:%G' "$M/etc/shadow")" = "640 root:kmem" ]
check "sshd drop-in key-only" grep -qx "PasswordAuthentication no" "$M/etc/ssh/sshd_config.d/10-bootstrap-key-only.conf"
check "hostname = ops" [ "$(cat "$M/etc/hostname")" = "ops" ]
check "sshd.service enabled" [ -L "$M/etc/systemd/system/multi-user.target.wants/sshd.service" ]
check "bootstrap-sudo enabled" [ -L "$M/etc/systemd/system/multi-user.target.wants/bootstrap-sudo.service" ]
check "jeos-firstboot flag removed" [ ! -e "$M/var/lib/YaST2/reconfig_system" ]
check "autorelabel marker" [ -e "$M/etc/selinux/.autorelabel" ]
check "no baked-in ssh host keys" bash -c "! ls '$M'/etc/ssh/ssh_host_* 2>/dev/null | grep -q ."
check "no machine-id content" bash -c "[ ! -s '$M/etc/machine-id' ]"
exit "$fail"
