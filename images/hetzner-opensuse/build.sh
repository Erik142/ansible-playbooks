#!/usr/bin/env bash
# Build the Hetzner Tumbleweed image with KIWI inside a privileged openSUSE Tumbleweed container.
#
#   ./build.sh [--out DIR] [--image-version X.Y.Z] [--engine docker|podman] [--allow-emulated]
#              [--preflight-only]
#
# Needs an x86_64 Linux host, root (or docker/podman access), ~15 GB free disk, internet.
# With Docker as a non-root user run it as `sudo ./build.sh --engine docker` unless the user is in
# the docker group. --preflight-only checks the host and exits before building anything.
# No cloud API calls are made. Result: DIR/<name>.raw.xz and DIR/<name>.raw.xz.sha256
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$here/out"
version="$(date +%Y.%m.%d)"
engine=""
allow_emulated=0
preflight_only=0
base_image="registry.opensuse.org/opensuse/tumbleweed:latest"

usage() { sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
die() { echo "build.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --out)             out="${2:?--out needs a directory}"; shift 2 ;;
    --image-version)   version="${2:?--image-version needs X.Y.Z}"; shift 2 ;;
    --engine)          engine="${2:?--engine needs docker or podman}"; shift 2 ;;
    --allow-emulated)  allow_emulated=1; shift ;;
    --preflight-only)  preflight_only=1; shift ;;
    -h|--help)         usage 0 ;;
    *)                 echo "unknown option: $1" >&2; usage 1 ;;
  esac
done

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--image-version must look like X.Y.Z, got '$version'"

if [ -z "$engine" ]; then
  if command -v podman >/dev/null; then engine=podman
  elif command -v docker >/dev/null; then engine=docker
  else die "neither podman nor docker found"; fi
fi
command -v "$engine" >/dev/null || die "$engine not found"

# Architecture guard: the image is x86_64. Building it under emulation is slow and loop/partition
# handling in emulated containers is unreliable, so it must be requested explicitly.
platform_args=()
case "$(uname -m)" in
  x86_64|amd64) ;;
  *)
    [ "$allow_emulated" = 1 ] || die "host is $(uname -m), not x86_64. Build on an x86_64 host (e.g. a Hetzner CX server), or pass --allow-emulated (slow, may fail)."
    platform_args=(--platform linux/amd64)
    ;;
esac
[ "$(uname -s)" = Linux ] || [ "$allow_emulated" = 1 ] || die "needs a Linux host (loop devices)"


# Host checks that would otherwise fail 15 minutes into the build.
preflight() {
  local failed=0 avail
  if [ "$(uname -s)" = Linux ]; then
    if ! grep -qw btrfs /proc/filesystems; then
      modprobe btrfs 2>/dev/null || true
    fi
    if grep -qw btrfs /proc/filesystems; then
      echo "preflight: ok   host kernel supports btrfs"
    else
      echo "preflight: FAIL host kernel has no btrfs support (kiwi cannot create the root filesystem)" >&2
      failed=1
    fi
    avail="$(df -BG --output=avail "$out" | tail -n1 | tr -dc '0-9')"
    if [ "${avail:-0}" -ge 15 ]; then
      echo "preflight: ok   ${avail} GB free in $out"
    else
      echo "preflight: FAIL only ${avail:-0} GB free in $out, need about 15 GB" >&2
      failed=1
    fi
    if [ "$(id -u)" -eq 0 ]; then
      if losetup -f >/dev/null 2>&1; then
        echo "preflight: ok   loop devices available"
      else
        echo "preflight: FAIL no free loop device (modprobe loop)" >&2
        failed=1
      fi
    else
      echo "preflight: note not root, loop devices are not checked (the container runs as root)"
    fi
  fi
  if "$engine" info >/dev/null 2>&1; then
    echo "preflight: ok   $engine daemon reachable"
    if "$engine" info 2>/dev/null | grep -qi 'userns'; then
      echo "preflight: FAIL $engine runs with user-namespace remapping: --privileged loop and partition devices do not work" >&2
      failed=1
    fi
  else
    echo "preflight: FAIL cannot talk to $engine (daemon down, or the user is not in the docker group: use sudo)" >&2
    failed=1
  fi
  return "$failed"
}

mkdir -p "$out"
out="$(cd "$out" && pwd)"

preflight || die "preflight failed, nothing was built"
[ "$preflight_only" = 0 ] || { echo "preflight: all good"; exit 0; }

echo ">> engine=$engine version=$version out=$out"

# The container script runs as root inside the container. The description is mounted read-only and
# copied, so the image-version rewrite never touches the repo.
read -r -d '' inner <<'EOS' || true
set -euo pipefail
zypper -n --gpg-auto-import-keys refresh
# kiwi itself plus what the oem/btrfs/BIOS+EFI disk build calls on the build host.
zypper -n install --no-recommends \
  python3-kiwi btrfsprogs e2fsprogs xfsprogs dosfstools mtools parted gptfdisk util-linux \
  kpartx lvm2 qemu-tools squashfs xz tar gawk rsync sudo \
  grub2 grub2-x86_64-efi shim
rm -rf /work && cp -a /description /work
sed -i "0,/<version>[^<]*<\/version>/s//<version>${IMAGE_VERSION}<\/version>/" /work/config.kiwi
grep -n '<version>' /work/config.kiwi
rm -rf /out/kiwi && mkdir -p /out/kiwi
kiwi-ng --profile Hetzner --type oem system build --description /work --target-dir /out/kiwi
raw="$(ls /out/kiwi/*.raw)"
echo ">> partition table of $raw"
sfdisk -d "$raw"
echo ">> compressing"
rm -f "$raw.xz"
xz -T0 -6 -k "$raw"
mv "$raw.xz" "/out/$(basename "$raw").xz"
rm -rf /out/kiwi/build
EOS

# --privileged and /dev bind: kiwi needs loop devices AND the loopNpM partition nodes, which udev
# creates on the host and which a container would otherwise never see.
"$engine" run --rm --privileged "${platform_args[@]}" \
  -e "IMAGE_VERSION=$version" \
  -v /dev:/dev \
  -v "$here":/description:ro \
  -v "$out":/out \
  "$base_image" bash -c "$inner"

xzfile="$(ls -t "$out"/*.raw.xz | head -n1)"
( cd "$out" && sha256sum "$(basename "$xzfile")" > "$(basename "$xzfile").sha256" && cat "$(basename "$xzfile").sha256" )
echo ">> done: $xzfile"
echo ">> uncompressed raw (kept for inspection): $(ls "$out"/kiwi/*.raw)"
