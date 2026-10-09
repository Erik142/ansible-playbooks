#!/usr/bin/env bash
# Runs INSIDE the bootstrap guest (Leap 16.0 aarch64, only used to build the root).
# Builds a openSUSE Tumbleweed aarch64 system with a btrfs root onto $TARGET_DEV
# (a blank disk), because no Tumbleweed aarch64 cloud/JeOS image is published.
#   env: TARGET_DEV (e.g. /dev/vdb), PUBKEY (ssh public key line for user fixture)
set -euxo pipefail
: "${TARGET_DEV:?}" "${PUBKEY:?}"
# The Leap host enforces SELinux; chroot into an unlabeled tree would be denied.
setenforce 0 || true
R=/mnt/tw
REPO=https://download.opensuse.org/ports/aarch64/tumbleweed/repo

zypper --non-interactive in gptfdisk btrfsprogs dosfstools parted
mount --make-rprivate "$R" 2>/dev/null || true
umount -R -l "$R" 2>/dev/null || true
udevadm settle; sleep 2
wipefs -a "$TARGET_DEV"
sgdisk --zap-all "$TARGET_DEV" || true
sgdisk -n1:0:+512M -t1:ef00 -c1:ESP -n2:0:0 -t2:8300 -c2:root "$TARGET_DEV"
partprobe "$TARGET_DEV" || true
sleep 2
P1="${TARGET_DEV}1"; P2="${TARGET_DEV}2"
mkfs.vfat -F32 -n ESP "$P1"
mkfs.btrfs -f -L root "$P2"

mkdir -p "$R"
mount "$P2" "$R"
btrfs subvolume create "$R/@"
btrfs subvolume create "$R/@/home"
btrfs subvolume create "$R/@/var"
btrfs subvolume create "$R/@/.snapshots"
ID=$(btrfs subvolume list "$R" | awk '$NF=="@"{print $2}')
btrfs subvolume set-default "$ID" "$R"
umount "$R"
mount "$P2" "$R"            # now mounts @ (default subvolume)
mkdir -p "$R/boot/efi"
mount "$P1" "$R/boot/efi"

zypper --root "$R" --non-interactive --gpg-auto-import-keys ar -f "$REPO/oss" oss
zypper --root "$R" --non-interactive --gpg-auto-import-keys ar -f "$REPO/non-oss" non-oss || true
zypper --root "$R" --non-interactive --gpg-auto-import-keys ar -f "https://download.opensuse.org/ports/aarch64/update/tumbleweed" update || true
zypper --root "$R" --non-interactive --gpg-auto-import-keys ref

# Base system. kernel-default + dracut for the initrd; grub2 for UEFI boot.
zypper --root "$R" --non-interactive --gpg-auto-import-keys in --no-recommends \
  patterns-base-minimal_base kernel-default dracut grub2-arm64-efi btrfsprogs \
  ca-certificates-mozilla openssh-server sudo NetworkManager iproute2 iputils parted util-linux-systemd \
  glibc-locale-base timezone vim-small which shadow systemd-network udev dosfstools \
  firewalld podman snapper sqlite3 zypper

# Chroot mounts.
for m in dev proc sys; do mount --rbind "/$m" "$R/$m"; done
mount --bind /sys/firmware/efi/efivars "$R/sys/firmware/efi/efivars" 2>/dev/null || true
cp /etc/resolv.conf "$R/etc/resolv.conf" 2>/dev/null || true

UUID_ROOT=$(blkid -s UUID -o value "$P2")
UUID_ESP=$(blkid -s UUID -o value "$P1")
cat >"$R/etc/fstab" <<EOF
UUID=$UUID_ROOT /           btrfs defaults                0 0
UUID=$UUID_ROOT /home       btrfs subvol=/@/home          0 0
UUID=$UUID_ROOT /var        btrfs subvol=/@/var           0 0
UUID=$UUID_ROOT /.snapshots btrfs subvol=/@/.snapshots    0 0
UUID=$UUID_ESP  /boot/efi   vfat  umask=0077              0 2
EOF
echo nas-vm-fixture >"$R/etc/hostname"
echo 'LANG=en_US.UTF-8' >"$R/etc/locale.conf"
echo 'KEYMAP=us' >"$R/etc/vconsole.conf"
ln -sf /usr/share/zoneinfo/UTC "$R/etc/localtime"

chroot "$R" /bin/bash -euxo pipefail <<EOS
systemd-machine-id-setup || true
useradd -m -s /bin/bash -g users fixture
passwd -l root || true
install -d -m 700 -o fixture -g users /home/fixture/.ssh
echo '$PUBKEY' >/home/fixture/.ssh/authorized_keys
chown fixture:users /home/fixture/.ssh/authorized_keys
chmod 600 /home/fixture/.ssh/authorized_keys
echo 'fixture ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/fixture
chmod 440 /etc/sudoers.d/fixture
systemctl enable sshd NetworkManager firewalld
# Key-only ssh.
install -d /etc/ssh/sshd_config.d
printf 'PasswordAuthentication no\nPermitRootLogin no\n' >/etc/ssh/sshd_config.d/10-fixture.conf
# Kernel cmdline: serial console for debugging, no quiet.
echo 'GRUB_CMDLINE_LINUX_DEFAULT="console=ttyAMA0,115200 console=tty0 selinux=0"' >>/etc/default/grub
echo 'GRUB_TIMEOUT=2' >>/etc/default/grub
dracut --regenerate-all --force
grub2-install --target=arm64-efi --efi-directory=/boot/efi --removable --no-nvram
grub2-mkconfig -o /boot/grub2/grub.cfg
EOS

sync
mount --make-rprivate "$R"
umount -R -l "$R"
sleep 2
echo BUILD-ROOT-OK
