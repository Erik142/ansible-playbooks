#!/usr/bin/env bash
# build-in-rescue.sh - write an openSUSE Tumbleweed (BTRFS + snapper) image onto
# the disk of a Hetzner Cloud server from inside Hetzner's rescue system, grow it
# to the full disk and make it SSH-reachable WITHOUT cloud-init.
#
# DESTROYS everything on the target disk. See README.md in this directory.
#
# Run as root in the rescue system (Debian, x86_64):
#   ./build-in-rescue.sh --pubkey-file ~/owner.pub --dry-run
#   ./build-in-rescue.sh --pubkey-file ~/owner.pub --yes
#
# The script never boots, reboots or powers off the machine.

set -euo pipefail

# ---------------------------------------------------------------------------
# Pinned image. The SHA256 below was copied from the mirror's .sha256 file on
# 2026-10-11 (https://download.opensuse.org/.../...Snapshot20261009.qcow2.sha256).
# At run time the script ALSO fetches that .sha256 file and requires all three
# values (pinned, mirror, actual file) to agree. Tumbleweed removes old
# snapshot files; if the URL 404s, pick a new image, set --image-url and
# --sha256 explicitly, and re-test (see README.md).
# ---------------------------------------------------------------------------
IMAGE_URL_DEFAULT='https://download.opensuse.org/tumbleweed/appliances/openSUSE-Tumbleweed-Minimal-VM.x86_64-1.0.0-kvm-and-xen-Snapshot20261009.qcow2'
IMAGE_SHA256_DEFAULT='3645b6233270d4b6f1680d62fbe277be4b00826e1b61b6ce5588d6f5f2d9df07'

# GPT partition type GUID "Linux x86-64 root (/)" - how the image marks its root.
ROOT_TYPE_GUID='4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709'

OWNER_USER='erikwahlberger'
OWNER_UID=1000
DISK_MIN_BYTES=$((30 * 1000 * 1000 * 1000))
DISK_MAX_BYTES=$((50 * 1000 * 1000 * 1000))

DISK='/dev/sda'
PUBKEY_FILE=''
IMAGE_URL="$IMAGE_URL_DEFAULT"
IMAGE_SHA256="$IMAGE_SHA256_DEFAULT"
IMAGE_FILE=''
WORKDIR='/root/hetzner-image-work'
NEW_HOSTNAME='ops'
ASSUME_YES=0
DRY_RUN=0
ALLOW_LOOP=0
SKIP_RESCUE_CHECK=0
MNT=''

usage() {
  cat <<'EOF'
Usage: build-in-rescue.sh --pubkey-file FILE [options]

Required:
  --pubkey-file FILE   File with exactly one 'ssh-ed25519 ...' PUBLIC key line.
                       It is installed for user erikwahlberger.
Options:
  --disk DEV           Target whole disk (default /dev/sda). ALL DATA IS LOST.
  --yes                Required to actually write anything.
  --dry-run            Validate everything, print the plan, change nothing.
  --image-url URL      Override the pinned image URL (also pass --sha256).
  --image-file FILE    Use an already downloaded qcow2 (still SHA256-checked).
  --sha256 HEX         Override the pinned SHA256 of the image.
  --hostname NAME      Hostname file content (default: ops).
  --workdir DIR        Download directory (default /root/hetzner-image-work).
  --skip-rescue-check  Skip only the 'is this the rescue system' heuristic (hostname
                       'rescue', /root/.oldroot, /etc/motd). All disk checks stay.
  --allow-loop         TEST ONLY: accept a loop device as target and skip the
                       rescue-system check. Never use on a real server.
  -h, --help           This help.
EOF
}

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Mutating commands go through run() so --dry-run can print instead of execute.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRY-RUN: %s\n' "$*"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --disk) DISK="${2:?--disk needs a value}"; shift 2 ;;
    --pubkey-file) PUBKEY_FILE="${2:?--pubkey-file needs a value}"; shift 2 ;;
    --image-url) IMAGE_URL="${2:?--image-url needs a value}"; shift 2 ;;
    --image-file) IMAGE_FILE="${2:?--image-file needs a value}"; shift 2 ;;
    --sha256) IMAGE_SHA256="${2:?--sha256 needs a value}"; shift 2 ;;
    --hostname) NEW_HOSTNAME="${2:?--hostname needs a value}"; shift 2 ;;
    --workdir) WORKDIR="${2:?--workdir needs a value}"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --allow-loop) ALLOW_LOOP=1; shift ;;
    --skip-rescue-check) SKIP_RESCUE_CHECK=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[ -n "$PUBKEY_FILE" ] || { usage >&2; die "--pubkey-file is required"; }
[ "$(id -u)" -eq 0 ] || die "must run as root"
[ "$(uname -m)" = "x86_64" ] || [ "$ALLOW_LOOP" -eq 1 ] || die "x86_64 only (got $(uname -m))"
[[ "$IMAGE_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "--sha256 must be 64 lowercase hex chars"
[[ "$NEW_HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "invalid hostname: $NEW_HOSTNAME"

# ---------------------------------------------------------------------------
# Public key validation (single ssh-ed25519 line, no options, no embedded junk)
# ---------------------------------------------------------------------------
[ -f "$PUBKEY_FILE" ] || die "pubkey file not found: $PUBKEY_FILE"
mapfile -t key_lines < <(grep -v '^[[:space:]]*$' "$PUBKEY_FILE" || true)
[ "${#key_lines[@]}" -eq 1 ] || die "pubkey file must contain exactly one non-empty line (found ${#key_lines[@]})"
PUBKEY_LINE="${key_lines[0]}"
[[ "$PUBKEY_LINE" =~ ^ssh-ed25519\ [A-Za-z0-9+/]+=*(\ [[:print:]]+)?$ ]] \
  || die "pubkey must look like 'ssh-ed25519 AAAA... [comment]' (no options prefix, no private key!)"
if command -v ssh-keygen >/dev/null 2>&1; then
  ssh-keygen -l -f "$PUBKEY_FILE" >/dev/null 2>&1 || die "ssh-keygen rejects the public key"
fi

# ---------------------------------------------------------------------------
# Environment and target disk guard rails
# ---------------------------------------------------------------------------
looks_like_rescue() {
  [ "$(hostname)" = "rescue" ] && return 0
  [ -d /root/.oldroot ] && return 0
  grep -qi 'rescue' /etc/motd 2>/dev/null && return 0
  return 1
}

if [ "$SKIP_RESCUE_CHECK" -eq 1 ]; then
  log "WARNING: --skip-rescue-check given: not verifying that this is the rescue system"
elif [ "$ALLOW_LOOP" -eq 0 ]; then
  looks_like_rescue || die "this does not look like Hetzner's rescue system (hostname 'rescue', /root/.oldroot or 'rescue' in /etc/motd). Refusing."
else
  log "WARNING: --allow-loop given: rescue-system check skipped, loop devices accepted (test mode)"
fi

[ -b "$DISK" ] || die "$DISK is not a block device"
DISK="$(readlink -f "$DISK")"
disk_base="$(basename "$DISK")"
[ -d "/sys/block/$disk_base" ] || die "$DISK is not a whole disk (no /sys/block/$disk_base): refusing partitions"
disk_type="$(lsblk -dno TYPE "$DISK" 2>/dev/null || true)"
if [ "$disk_type" != "disk" ]; then
  if [ "$disk_type" = "loop" ] && [ "$ALLOW_LOOP" -eq 1 ]; then :; else
    die "$DISK has type '${disk_type:-unknown}', expected 'disk'"
  fi
fi
disk_bytes="$(blockdev --getsize64 "$DISK")"
{ [ "$disk_bytes" -ge "$DISK_MIN_BYTES" ] && [ "$disk_bytes" -le "$DISK_MAX_BYTES" ]; } \
  || die "$DISK is $disk_bytes bytes; expected between $DISK_MIN_BYTES and $DISK_MAX_BYTES (30-50 GB)"

# Nothing on the disk may be mounted or used as swap; the running root must not live on it.
if [ -n "$(lsblk -nro MOUNTPOINTS "$DISK" | tr -d '[:space:]')" ]; then
  lsblk -o NAME,FSTYPE,MOUNTPOINTS "$DISK" >&2
  die "something on $DISK is mounted"
fi
if awk 'NR>1 {print $1}' /proc/swaps | grep -q "^$DISK"; then
  die "swap is active on $DISK"
fi
root_src="$(findmnt -no SOURCE / || true)"
case "$root_src" in
  "$DISK"*) die "the running root filesystem ($root_src) is on $DISK" ;;
  *) : ;;
esac

part_path() { # part_path <disk> <n>
  case "$1" in
    *[0-9]) printf '%sp%s' "$1" "$2" ;;
    *) printf '%s%s' "$1" "$2" ;;
  esac
}

log "Target: $DISK  size=$disk_bytes bytes"
log "Current layout of $DISK (will be DESTROYED):"
lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL "$DISK" || true

# ---------------------------------------------------------------------------
# Plan / confirmation
# ---------------------------------------------------------------------------
cat <<EOF

PLAN
  1. apt-get install missing tools (qemu-utils gdisk btrfs-progs util-linux parted curl)
  2. download + verify image (pinned sha256 == mirror .sha256 == file)
  3. zero start/end of $DISK, qemu-img convert -> $DISK
  4. sgdisk -e; grow the GPT 'Linux x86-64 root' partition to the end; btrfs resize max
  5. inject user $OWNER_USER (uid $OWNER_UID, locked password), authorized_keys, sudoers,
     hostname '$NEW_HOSTNAME', sshd enabled, jeos-firstboot wizard skipped,
     sudo-install-on-first-boot unit (image ships without sudo), SELinux autorelabel
  6. umount, sync. NO boot, NO poweroff.
EOF

if [ "$DRY_RUN" -eq 0 ] && [ "$ASSUME_YES" -ne 1 ]; then
  die "refusing to destroy $DISK without --yes (use --dry-run to preview)"
fi

# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------
declare -A tool_pkg=(
  [qemu-img]=qemu-utils [sgdisk]=gdisk [btrfs]=btrfs-progs [partprobe]=parted
  [lsblk]=util-linux [curl]=curl [blkid]=util-linux [wipefs]=util-linux
)
missing_pkgs=()
for t in "${!tool_pkg[@]}"; do
  command -v "$t" >/dev/null 2>&1 || missing_pkgs+=("${tool_pkg[$t]}")
done
if [ "${#missing_pkgs[@]}" -gt 0 ]; then
  mapfile -t missing_pkgs < <(printf '%s\n' "${missing_pkgs[@]}" | sort -u)
  log "installing missing packages: ${missing_pkgs[*]}"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRY-RUN: apt-get install -y %s\n' "${missing_pkgs[*]}"
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq "${missing_pkgs[@]}"
  fi
fi

# ---------------------------------------------------------------------------
# Download and verify
# ---------------------------------------------------------------------------
verify_image() { # sets IMG
  local mirror_sum actual
  if [ -n "$IMAGE_FILE" ]; then
    [ -f "$IMAGE_FILE" ] || die "image file not found: $IMAGE_FILE"
    IMG="$IMAGE_FILE"
  else
    IMG="$WORKDIR/$(basename "$IMAGE_URL")"
  fi
  mirror_sum="$(curl -fsSL --retry 3 "$IMAGE_URL.sha256" | awk 'NR==1 {print $1}')" \
    || die "cannot fetch $IMAGE_URL.sha256"
  [[ "$mirror_sum" =~ ^[0-9a-f]{64}$ ]] || die "mirror .sha256 is not a sha256: '$mirror_sum'"
  [ "$mirror_sum" = "$IMAGE_SHA256" ] \
    || die "pinned sha256 ($IMAGE_SHA256) != mirror .sha256 ($mirror_sum). The mirror image changed: review, then pass --sha256."
  log "mirror .sha256 matches the pinned value"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRY-RUN: download %s -> %s and sha256sum it\n' "$IMAGE_URL" "$IMG"
    return 0
  fi
  if [ -z "$IMAGE_FILE" ]; then
    mkdir -p "$WORKDIR"
    local avail_kb
    avail_kb="$(df -Pk "$WORKDIR" | awk 'NR==2 {print $4}')"
    [ "$avail_kb" -gt 700000 ] || die "less than ~700 MB free in $WORKDIR (rescue root is RAM-backed)"
    if [ ! -f "$IMG" ]; then
      log "downloading $IMAGE_URL"
      local -a curl_opts=(-fL --retry 3)
      [ -t 2 ] || curl_opts+=(-sS)
      curl "${curl_opts[@]}" -o "$IMG.part" "$IMAGE_URL"
      mv "$IMG.part" "$IMG"
    fi
  fi
  actual="$(sha256sum "$IMG" | awk '{print $1}')"
  [ "$actual" = "$IMAGE_SHA256" ] || die "sha256 of $IMG is $actual, expected $IMAGE_SHA256"
  log "image sha256 verified: $actual"
}
IMG=''
verify_image

if [ "$DRY_RUN" -eq 1 ]; then
  log "dry-run finished; nothing was changed."
  exit 0
fi

# ---------------------------------------------------------------------------
# Cleanup trap
# ---------------------------------------------------------------------------
cleanup() {
  local rc=$?
  set +e
  if [ -n "$MNT" ] && mountpoint -q "$MNT"; then
    sync
    umount -R "$MNT" || umount -Rl "$MNT"
  fi
  [ -n "$MNT" ] && rmdir "$MNT" 2>/dev/null
  if [ "$rc" -ne 0 ]; then
    printf 'FAILED (exit %s). The disk %s is in an undefined state; re-run the script from the start.\n' "$rc" "$DISK" >&2
  fi
  exit "$rc"
}
trap cleanup EXIT

settle() {
  command -v udevadm >/dev/null 2>&1 && udevadm settle --timeout=30 || true
}

# Wait for partition node; on loop devices inside containers udev is absent so
# create the node from sysfs (test mode only).
ensure_part_node() { # ensure_part_node <n>
  local n="$1" node devno
  node="$(part_path "$DISK" "$n")"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -b "$node" ] && return 0
    if [ "$ALLOW_LOOP" -eq 1 ] && [ -r "/sys/block/$disk_base/$(basename "$node")/dev" ]; then
      devno="$(cat "/sys/block/$disk_base/$(basename "$node")/dev")"
      mknod "$node" b "${devno%:*}" "${devno#*:}"
      continue
    fi
    sleep 1
    settle
  done
  [ -b "$node" ] || die "partition node $node did not appear"
}

reread_ptable() {
  partprobe "$DISK" 2>/dev/null || blockdev --rereadpt "$DISK" 2>/dev/null || true
  settle
}

# ---------------------------------------------------------------------------
# Write the image
# ---------------------------------------------------------------------------
log "wiping signatures and the first/last 16 MiB of $DISK"
wipefs -a -f "$DISK" >/dev/null
dd if=/dev/zero of="$DISK" bs=1M count=16 conv=fsync status=none
dd if=/dev/zero of="$DISK" bs=512 count=32768 seek=$((disk_bytes / 512 - 32768)) conv=fsync status=none

log "writing image (qemu-img convert, this takes a few minutes)"
qemu-img convert -p -f qcow2 -O raw "$IMG" "$DISK"
sync

log "relocating GPT backup header to the end of the disk"
sgdisk -e "$DISK" >/dev/null
reread_ptable

# ---------------------------------------------------------------------------
# Find and grow the root partition (by GPT type GUID, not by hardcoded offsets)
# ---------------------------------------------------------------------------
mapfile -t part_nums < <(sgdisk -p "$DISK" | awk '/^ +[0-9]+ /{print $1}')
[ "${#part_nums[@]}" -gt 0 ] || die "no partitions found after writing the image"
ROOT_N=''
max_last=0
for n in "${part_nums[@]}"; do
  info="$(sgdisk -i "$n" "$DISK")"
  guid="$(awk -F': ' '/^Partition GUID code/ {split($2, a, " "); print toupper(a[1])}' <<<"$info")"
  last="$(awk -F': ' '/^Last sector/ {split($2, a, " "); print a[1]}' <<<"$info")"
  [ "$last" -gt "$max_last" ] && max_last="$last"
  if [ "$guid" = "$ROOT_TYPE_GUID" ]; then
    [ -z "$ROOT_N" ] || die "more than one partition of type $ROOT_TYPE_GUID"
    ROOT_N="$n"
  fi
done
[ -n "$ROOT_N" ] || die "no partition of type $ROOT_TYPE_GUID (Linux x86-64 root) in the image"
info="$(sgdisk -i "$ROOT_N" "$DISK")"
root_first="$(awk -F': ' '/^First sector/ {split($2, a, " "); print a[1]}' <<<"$info")"
root_last="$(awk -F': ' '/^Last sector/ {split($2, a, " "); print a[1]}' <<<"$info")"
root_uuid_gpt="$(awk -F': ' '/^Partition unique GUID/ {print $2}' <<<"$info")"
root_name="$(sed -n "s/^Partition name: '\(.*\)'$/\1/p" <<<"$info")"
[ "$root_last" -eq "$max_last" ] || die "root partition $ROOT_N is not the last partition; refusing to grow"
log "root partition: #$ROOT_N first=$root_first last=$root_last name='$root_name'"

log "growing partition $ROOT_N to the end of the disk (start sector and PARTUUID preserved)"
sgdisk -d "$ROOT_N" -n "$ROOT_N:$root_first:0" -t "$ROOT_N:$ROOT_TYPE_GUID" \
  -c "$ROOT_N:$root_name" -u "$ROOT_N:$root_uuid_gpt" "$DISK" >/dev/null
sgdisk -v "$DISK" | tail -n 3
reread_ptable
ensure_part_node "$ROOT_N"
ROOT_DEV="$(part_path "$DISK" "$ROOT_N")"
fstype="$(blkid -o value -s TYPE "$ROOT_DEV" || true)"
[ "$fstype" = "btrfs" ] || die "$ROOT_DEV has filesystem '$fstype', expected btrfs"

# ---------------------------------------------------------------------------
# Mount: the DEFAULT subvolume is the real root of this image (a snapper
# snapshot, @/.snapshots/1/snapshot), not '@'. Other subvolumes come from fstab.
# ---------------------------------------------------------------------------
MNT="$(mktemp -d /mnt/hz-root.XXXXXX)"
mount -t btrfs "$ROOT_DEV" "$MNT"
log "default subvolume: $(btrfs subvolume get-default "$MNT")"
[ -f "$MNT/etc/os-release" ] || die "default subvolume has no /etc/os-release: unexpected image layout"
grep -q '^ID="\?opensuse-tumbleweed' "$MNT/etc/os-release" || die "not a Tumbleweed root: $(grep '^ID=' "$MNT/etc/os-release")"

log "btrfs filesystem resize max"
btrfs filesystem resize max "$MNT" >/dev/null

mount_fstab_subvol() { # mount_fstab_subvol <mountpoint-in-image>
  local target="$1" subvol
  subvol="$(awk -v t="$target" '$1 !~ /^#/ && $2 == t && $3 == "btrfs" {n = split($4, o, ","); for (i = 1; i <= n; i++) if (o[i] ~ /^subvol=/) {sub(/^subvol=/, "", o[i]); print o[i]}}' "$MNT/etc/fstab")"
  [ -n "$subvol" ] || die "no btrfs subvol for $target in the image's /etc/fstab"
  mount -t btrfs -o "subvol=$subvol" "$ROOT_DEV" "$MNT$target"
}
mount_fstab_subvol /var
mount_fstab_subvol /home

# ---------------------------------------------------------------------------
# Injection
# ---------------------------------------------------------------------------
USERS_GID="$(awk -F: '$1 == "users" {print $3}' "$MNT/etc/group")"
[ -n "$USERS_GID" ] || die "group 'users' not found in the image's /etc/group"
! grep -q "^$OWNER_USER:" "$MNT/etc/passwd" || die "user $OWNER_USER already exists in the image"
! awk -F: -v u="$OWNER_UID" '$3 == u {f = 1} END {exit !f}' "$MNT/etc/passwd" || die "uid $OWNER_UID already used in the image"

log "creating user $OWNER_USER (uid $OWNER_UID, gid $USERS_GID 'users', locked password)"
[ -z "$(tail -c1 "$MNT/etc/passwd")" ] || echo >>"$MNT/etc/passwd"
[ -z "$(tail -c1 "$MNT/etc/shadow")" ] || echo >>"$MNT/etc/shadow"
# '>>' keeps the existing owner/mode of passwd and shadow.
printf '%s:x:%s:%s:%s:/home/%s:/bin/bash\n' "$OWNER_USER" "$OWNER_UID" "$USERS_GID" "$OWNER_USER" "$OWNER_USER" >>"$MNT/etc/passwd"
printf '%s:*:%s::::::\n' "$OWNER_USER" "$(( $(date +%s) / 86400 ))" >>"$MNT/etc/shadow"

HOME_DIR="$MNT/home/$OWNER_USER"
install -d -m 0700 -o "$OWNER_UID" -g "$USERS_GID" "$HOME_DIR" "$HOME_DIR/.ssh"
install -m 0600 -o "$OWNER_UID" -g "$USERS_GID" /dev/null "$HOME_DIR/.ssh/authorized_keys"
printf '%s\n' "$PUBKEY_LINE" >"$HOME_DIR/.ssh/authorized_keys"

log "sudoers drop-in"
install -d -m 0750 -o 0 -g 0 "$MNT/etc/sudoers.d"
sudoers_tmp="$(mktemp)"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$OWNER_USER" >"$sudoers_tmp"
if command -v visudo >/dev/null 2>&1; then
  visudo -cf "$sudoers_tmp" >/dev/null || die "visudo rejects the sudoers drop-in"
else
  log "visudo not available in the rescue system; sudoers line is a fixed constant, not validated"
fi
install -m 0440 -o 0 -g 0 "$sudoers_tmp" "$MNT/etc/sudoers.d/$OWNER_USER"
rm -f "$sudoers_tmp"

log "hostname -> $NEW_HOSTNAME"
printf '%s\n' "$NEW_HOSTNAME" >"$MNT/etc/hostname"

enable_unit() { # enable_unit <unit> <target>   (what 'systemctl --root enable' does for WantedBy)
  local unit="$1" target="$2" src=""
  for d in /etc/systemd/system /usr/lib/systemd/system; do
    [ -f "$MNT$d/$unit" ] && { src="$d/$unit"; break; }
  done
  [ -n "$src" ] || die "unit $unit not found in image"
  install -d -m 0755 "$MNT/etc/systemd/system/$target.wants"
  ln -sfn "$src" "$MNT/etc/systemd/system/$target.wants/$unit"
}
enable_unit sshd.service multi-user.target

# Defence in depth until the playbook's security role takes over: the image's sshd
# defaults allow password logins (harmless while every password is locked).
install -d -m 0755 -o 0 -g 0 "$MNT/etc/ssh/sshd_config.d"
install -m 0644 -o 0 -g 0 /dev/null "$MNT/etc/ssh/sshd_config.d/10-bootstrap-key-only.conf"
cat >"$MNT/etc/ssh/sshd_config.d/10-bootstrap-key-only.conf" <<'EOF2'
# Written by tools/hetzner-image/build-in-rescue.sh: key-only until the playbook hardens sshd.
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF2

log "skipping the jeos-firstboot wizard (removing /var/lib/YaST2/reconfig_system)"
if [ -e "$MNT/var/lib/YaST2/reconfig_system" ]; then log "  flag present in image, removing"; fi
rm -f "$MNT/var/lib/YaST2/reconfig_system"

log "installing first-boot sudo bootstrap unit (the image ships without sudo)"
cat >"$MNT/etc/systemd/system/bootstrap-sudo.service" <<'EOF'
[Unit]
Description=Install sudo on first boot (openSUSE Minimal-VM image ships without it)
Wants=network-online.target
After=network-online.target
ConditionPathExists=!/usr/bin/sudo
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=/usr/bin/zypper --non-interactive install --no-recommends sudo
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "$MNT/etc/systemd/system/bootstrap-sudo.service"
enable_unit bootstrap-sudo.service multi-user.target

# Never ship SSH host keys inside a snapshot: every server must generate its own.
for k in "$MNT"/etc/ssh/ssh_host_*; do
  [ -e "$k" ] && { log "removing baked-in host key $k"; rm -f "$k"; }
done
# A baked-in machine-id would be shared by all servers created from the snapshot.
if [ -s "$MNT/etc/machine-id" ]; then
  log "truncating baked-in /etc/machine-id"
  : >"$MNT/etc/machine-id"
fi

log "making sure no account has a usable password"
locked_tmp="$(mktemp)"
awk -F: -v OFS=: '$2 !~ /^[!*]/ {print $1 > "/dev/stderr"; $2 = "*"} {print}' "$MNT/etc/shadow" >"$locked_tmp"
cat "$locked_tmp" >"$MNT/etc/shadow"
rm -f "$locked_tmp"
awk -F: '$2 !~ /^[!*]/ {bad = 1} END {exit bad}' "$MNT/etc/shadow" || die "shadow still has usable password hashes"
awk -F: '$1 == "root" && $2 ~ /^[!*]/ {ok = 1} END {exit !ok}' "$MNT/etc/shadow" || die "root is not locked"

log "SELinux: files written from the rescue system carry no labels -> request autorelabel"
if [ -f "$MNT/etc/selinux/config" ]; then
  grep -E '^SELINUX=' "$MNT/etc/selinux/config" || true
  : >"$MNT/etc/selinux/.autorelabel"
else
  log "  image has no /etc/selinux/config; skipping"
fi

# ---------------------------------------------------------------------------
# Verify, then unmount
# ---------------------------------------------------------------------------
log "verification (before unmount)"
[ "$(stat -c '%a %u:%g' "$HOME_DIR/.ssh")" = "700 $OWNER_UID:$USERS_GID" ] || die ".ssh perms wrong"
[ "$(stat -c '%a %u:%g' "$HOME_DIR/.ssh/authorized_keys")" = "600 $OWNER_UID:$USERS_GID" ] || die "authorized_keys perms wrong"
[ "$(stat -c '%a %u:%g' "$MNT/etc/sudoers.d/$OWNER_USER")" = "440 0:0" ] || die "sudoers perms wrong"
[ ! -e "$MNT/var/lib/YaST2/reconfig_system" ] || die "jeos-firstboot flag still present"
df -h "$MNT" | tail -n 1
btrfs filesystem usage -h "$MNT" | sed -n '1,8p'

sync
umount -R "$MNT"
rmdir "$MNT"
MNT=''
sync

log "btrfs check (read-only)"
btrfs check --readonly "$ROOT_DEV" 2>&1 | tail -n 6

cat <<EOF

DONE
  disk           : $DISK (root partition $ROOT_DEV, grown to the end of the disk)
  image          : $(basename "$IMG") sha256 $IMAGE_SHA256
  login          : ssh $OWNER_USER@<server-ip>  (key only; passwords are locked everywhere)
  sudo           : installed by bootstrap-sudo.service within ~1 min of first boot
  hostname       : $NEW_HOSTNAME
NEXT: power off from the Hetzner console/API, take a snapshot, create servers from it.
This script did NOT boot, reboot or power off anything.
EOF
