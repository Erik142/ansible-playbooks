# Tumbleweed image for Hetzner Cloud (KIWI)

A version-controlled [KIWI](https://osinside.github.io/kiwi/) description that builds an
**openSUSE Tumbleweed x86_64 raw disk image** for Hetzner Cloud (CX23, legacy BIOS/CSM boot,
DHCP on virtio-net). It replaces the "write the stock Minimal-VM image in rescue mode and inject
the user" approach in `../tools/hetzner-image/`: here cloud-init is part of the image, so the user,
SSH key and sudo rule come from the user-data you pass to `hcloud server create`.

**Status: validated statically only, never booted. See "UNVERIFIED" at the end.**

## What you get

| Item | Value |
|---|---|
| Root filesystem | BTRFS, openSUSE default subvolumes, root is a snapper snapshot (`btrfs_root_is_snapshot`), quota groups on |
| Snapper | `/etc/snapper/configs/root` created by KIWI, tuned by `disk.sh` (no timeline, NUMBER_LIMIT=2-10); `snapper-zypp-plugin` + `grub2-snapper-plugin` installed |
| Boot | GPT, BIOS boot partition (grub2 i386-pc) + 512 MB ESP (grub2 x86_64-efi), `firmware="uefi"` = KIWI's hybrid mode. **Not** grub2-bls / systemd-boot. `shim` installed; no Secure Boot needed on Hetzner |
| SELinux | enforcing, targeted, `security=selinux selinux=1`; full relabel once in the first-boot initrd |
| Network | NetworkManager (upstream default), DHCP |
| First-boot config | cloud-init + `cloud-init-config-suse`, datasource list `Hetzner, NoCloud, None` |
| Users | none baked in; root locked (`passwd -l`), `sudo` installed, SSH key-only, `PermitRootLogin no` |
| Root growth | `dracut-kiwi-oem-repart` in the initrd (systemd-repart + growfs, KIWI `oem-resize`, default on for `image="oem"`); cloud-init's growpart/resizefs run afterwards as a no-op or a fallback |
| Not included | jeos-firstboot wizard, firewalld, Xen tools, docs |
| Image size | 6 GB disk, grown to the server disk (40 GB on CX23) at first boot |

## Upstream provenance

Derived from the **openSUSE:Factory package `kiwi-templates-Minimal`** (the source of the
Tumbleweed "Minimal-VM" images on get.opensuse.org):

- source: `https://api.opensuse.org/public/source/openSUSE:Factory/kiwi-templates-Minimal`
  (browse: https://build.opensuse.org/package/show/openSUSE:Factory/kiwi-templates-Minimal)
- revision used: OBS **rev 44**, srcmd5 `6b11542362c85adf39416f9e3c4afeb1`, spec `Version: 84.87.1`
  (fetched 2026-10-11); files `Minimal.kiwi`, `config.sh`, `disk.sh`
- `github.com/openSUSE/kiwi-descriptions` does not exist (404); the OSInside/kiwi-descriptions
  repo has no Minimal template. OBS is the source of truth.
- KIWI version used for schema validation: python3-kiwi 10.3.11 (Tumbleweed, 2026-10-11)

To diff against the current upstream (our files are intentionally not vendored here):

```sh
U=https://api.opensuse.org/public/source/openSUSE:Factory/kiwi-templates-Minimal
curl -sL $U/Minimal.kiwi -o /tmp/Minimal.kiwi
curl -sL $U/config.sh    -o /tmp/config.sh
curl -sL $U/disk.sh      -o /tmp/disk.sh
diff -u /tmp/config.sh config.sh; diff -u /tmp/disk.sh disk.sh; diff -u /tmp/Minimal.kiwi config.kiwi
```

File names: `config.sh` and `disk.sh` keep their upstream names. KIWI's `images.sh` is for the
initrd/boot image (kiwi-ng 10 with dracut does not use it) and upstream has none, so none here.
`config.kiwi` is upstream's `Minimal.kiwi` (the name is free; `kiwi-ng` picks `*.kiwi`).

### Intent vs upstream (every change; grep for `HETZNER:`)

`config.kiwi` (one profile `Hetzner` = upstream `kvm-and-xen` filesystem/boot + upstream `Cloud` packages):

| Change | Why |
|---|---|
| All profiles but one removed (VMware, HyperV, RPi, s390x, ppc64le, sdboot, grub-bls, KubeVirt, aarch64) | Not needed; `Hetzner` is `arch="x86_64"` |
| Type attributes copied from `kvm-and-xen`: btrfs, `btrfs_quota_groups`, `btrfs_root_is_snapshot`, `firmware="uefi"`, `efipartsize=512`, `bootkernel="custom"`, `by-uuid`, systemdisk volumes incl. `boot/grub2/i386-pc` and `x86_64-efi` | BTRFS + snapper + BIOS/EFI hybrid |
| No `format="qcow2"`; `<bootloader timeout="1">` (from Cloud) | raw is what hcloud-upload-image and `dd` take; fast boot |
| `<size>` 6 G instead of 24 G | smaller upload, root is grown on first boot anyway |
| `<repository>` = plain `download.opensuse.org/tumbleweed/repo/oss/` instead of `obsrepositories:/` | `obsrepositories:/` only works inside OBS |
| Packages: Cloud's `cloud-init`, `cloud-init-config-suse`, `kernel-default-base`, `qemu-guest-agent`, `openSUSE-release-appliance-openstack` | cloud-init based provisioning |
| Packages: kvm-and-xen's `btrfsprogs`, `btrfsmaintenance`, `snapper*`, `grub2-snapper-plugin`, `grub2-branding-openSUSE`, `grub2-x86_64-efi`, `shim` | snapper + EFI |
| **Added** `sudo` | Hetzner user-data grants `sudo: ALL=(ALL) NOPASSWD:ALL`; upstream images ship no sudo |
| **Dropped** `jeos-firstboot`, `firewalld`, `xen-tools-domU`, `xen-libs`, `xfsprogs`, `rsyslog` comment | no wizard, no firewall (Hetzner Cloud Firewall is used), KVM guest, btrfs |

`config.sh` (diff is small; s390x/ppc64le/RPi/HyperV/sdbootutil branches removed):

- jeos-firstboot enable block replaced by `systemctl mask systemd-firstboot.service` (otherwise
  systemd-firstboot would prompt on the console at first boot because machine-id is removed) and
  `passwd -l root`.
- firewalld enable block removed.
- `touch /etc/selinux/.autorelabel` (upstream gets a labelled system via the jeos-firstboot flow;
  here the `selinux-autorelabel` dracut module relabels once in the first-boot initrd, then removes the marker).

`disk.sh`: verbatim upstream (snapper tuning; the sdbootutil block is dead code without sdbootutil).

`root/` overlay (new, not in upstream):

- `etc/cloud/cloud.cfg.d/90_hetzner.cfg`: `datasource_list: [ Hetzner, NoCloud, None ]`, `ssh_pwauth: false`
- `etc/ssh/sshd_config.d/10-hetzner-key-only.conf`: no passwords, no root login

## Build

Needs an **x86_64 Linux host** with root and Docker or Podman, ~15 GB free, internet. A Hetzner
CX23/CX33 (x86) running any Linux with docker/podman is fine; delete it afterwards.
`build.sh` refuses to run on other architectures unless `--allow-emulated` is given (untested,
slow, partition devices in emulated containers do not work reliably; this was observed on Docker
Desktop on arm64: KIWI failed with `/dev/loop0p1 does not exist`).

```sh
# on the builder (Debian/Ubuntu example)
apt-get update && apt-get install -y podman git xz-utils        # or docker.io
git clone <this repo> && cd ansible-playbooks/ops-de-wahlberger-dev/image
sudo ./build.sh --out /root/out --image-version 2026.10.11
```

With Docker instead of podman (engine is auto-detected; podman wins if both exist), and as a non-root
user without docker-group membership, use `sudo`. Check the host first, it takes seconds:

```sh
sudo ./build.sh --engine docker --preflight-only
sudo ./build.sh --engine docker --out ~/hetzner-image-out --image-version 2026.10.11
# result: /root/out/openSUSE-Tumbleweed-Hetzner.x86_64-2026.10.11.raw.xz  (+ .sha256)
```

`build.sh` starts a privileged `registry.opensuse.org/opensuse/tumbleweed` container (with
`-v /dev:/dev` so the loop partition nodes exist), installs `python3-kiwi` and the disk tooling,
runs `kiwi-ng --profile Hetzner --type oem system build`, prints `sfdisk -d` of the result,
compresses with `xz` and writes the sha256. Run it twice and the packages differ (rolling
Tumbleweed): reproducible in procedure, not bit-for-bit.

### Inspect the result before uploading (recommended)

```sh
raw=$(ls /root/out/kiwi/*.raw)
sfdisk -l "$raw"                      # expect GPT: bios_grub (EF02) ~2M, EFI System 512M, Linux root
lo=$(losetup -fP --show "$raw"); blkid "${lo}"p*         # expect vfat + btrfs
mount "${lo}p3" /mnt && ls /mnt/@/.snapshots 2>/dev/null; ls /mnt/etc/snapper/configs/ 2>/dev/null
btrfs subvolume list /mnt; umount /mnt; losetup -d "$lo"
```
(partition numbers/layout of the root subvolume may differ; the point is: btrfs, a snapper config,
a bios_grub partition, an ESP.)

## Upload as a Hetzner snapshot

### A) hcloud-upload-image (https://github.com/apricote/hcloud-upload-image, v1.5.0 checked 2026-10-11)

Takes a **raw** image, optionally compressed with `bz2`, `xz` or `zstd`. (qcow2 is limited to
~960 MB by the rescue system, so use raw.) It creates a temporary server, writes the image from
the rescue system, snapshots it and deletes the server (costs a few cents).

```sh
export HCLOUD_TOKEN=...      # project token, read+write; never commit it
hcloud-upload-image upload \
  --image-path /root/out/openSUSE-Tumbleweed-Hetzner.x86_64-2026.10.11.raw.xz \
  --architecture x86 --compression xz \
  --description "Tumbleweed btrfs+snapper+cloud-init 2026.10.11" \
  --labels os=tumbleweed,source=kiwi --location nbg1
# prints the snapshot id
```
Install: `.deb`/`.rpm`/binaries from the GitHub releases, or `go install github.com/apricote/hcloud-upload-image@latest`.
Note: the temporary server must be an x86 type (`--architecture x86`); the CX23 server type
you later use must be available in the same location.

### B) Manual: dd in the rescue system (fallback)

1. Create a throwaway CX23 (any image), enable rescue (`hcloud server enable-rescue --type linux64 <name>`), reboot into it.
2. Put the image there (the rescue root is RAM-backed, ~1 GB: stream it, do not store it):
   ```sh
   curl -fsSL https://YOUR-HOST/image.raw.xz | xz -dc | dd of=/dev/sda bs=4M conv=fsync status=progress
   ```
   (or `ssh builder 'cat out/image.raw.xz' | xz -dc | dd of=/dev/sda ...`; verify the sha256 of the .xz first)
3. `sgdisk -e /dev/sda` is not needed (oem-repart fixes the GPT on first boot), but harmless if gdisk is present.
4. `poweroff`, then `hcloud server create-image --type snapshot --description "..." <name>`; delete the throwaway server.

## Create the server

`cloud-init.yml` (user-data; Hetzner hands it to cloud-init via its metadata service):

```yaml
#cloud-config
users:
  - name: erikwahlberger
    gecos: Erik Wahlberger
    groups: [users]
    shell: /bin/bash
    lock_passwd: true
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... erik@laptop
ssh_pwauth: false
disable_root: true
```

```sh
hcloud server create \
  --name ops \
  --type cx23 \
  --location nbg1 \
  --image <snapshot-id> \
  --firewall <firewall-name-or-id> \
  --without-ipv6 \
  --user-data-from-file cloud-init.yml
```
No `--ssh-key`: with a locked root and `PermitRootLogin no` it would do nothing useful.
The group `wheel` does not exist in this image; use `users` (as in the old tools/hetzner-image notes).

## First-boot checks

Allow 1-3 minutes (SELinux relabel + growth + cloud-init).

```sh
ssh erikwahlberger@<ip>
sudo -n true && echo sudo-ok
df -h /                       # ~38G size (40 GB disk) -> root grown
findmnt -no FSTYPE,SOURCE /   # btrfs
findmnt -t btrfs              # subvolumes: /home /root /opt /srv /usr/local /var ...
sudo snapper list-configs     # root  /
sudo snapper list             # snapshot 1 (first root filesystem)
getenforce                    # Enforcing
cloud-init status --long      # status: done, datasource: DataSourceHetzner
sudo passwd -S root           # L (locked)
systemctl is-enabled sshd NetworkManager cloud-init cloud-final
```
Failure triage: Hetzner web console (VNC) shows grub/kernel/relabel output; `journalctl -b`,
`/var/log/cloud-init.log`, `sudo ausearch -m avc -ts boot`.

## UNVERIFIED until built and booted on x86_64

Validated: XML is well-formed, passes KIWI 10.3.11's schema (`kiwi-ng ... image info`), every
package name exists in the x86_64 Tumbleweed OSS repo (2026-10-11), `config.sh`/`build.sh` pass
`bash -n`/shellcheck, and a **native aarch64 dry run** (same description with arm64 grub packages
and the ports repo) installed the package set and ran `config.sh` successfully in the chroot
(sudo/cloud-init/snapper/btrfsprogs/dracut-kiwi-oem-repart/selinux-autorelabel present; jeos-firstboot and
firewalld absent; SELinux enforcing; `.autorelabel` set; root locked; systemd-firstboot masked;
cloud-init units enabled; datasource and sshd overlays in place). The disk-creation step failed
only because Docker Desktop on macOS does not provide loop partition nodes, so **no image file
was produced and nothing below was observed**:

- the disk build itself: GPT with bios_grub + ESP + btrfs root; `grub2-install` for i386-pc and EFI;
  `SNAPPER_CONFIGS="root"` assertion in `disk.sh` (the chroot shows it empty before the disk step, KIWI fills it later; same as upstream)
- BIOS boot on Hetzner CX23 (the stock Cloud profile booted there; this one adds a btrfs root and snapper grub plugin)
- oem-repart growing a btrfs root with the BIOS boot partition present, and relocating the backup GPT when the 6 GB image is written to a 40 GB disk (fallback: cloud-init growpart/resizefs, or `sgdisk -e` + `btrfs filesystem resize max /`)
- the SELinux relabel in the first-boot initrd actually running (marker `/etc/selinux/.autorelabel`), and enforcing mode working with btrfs subvolumes; snapper snapshot 1 relabel state (KIWI issue 2709)
- cloud-init's Hetzner datasource with NetworkManager (network config rendering, user/key/sudo creation), `cloud-init status` = done
- `-v /dev:/dev` + `--privileged` being enough for loop partitions on the builder host (rootless podman will not work)
- no first-boot console prompt (systemd-firstboot masked, jeos-firstboot absent)
- `sudo` rule from user-data landing in `/etc/sudoers.d` (the base `sudo` package includes `#includedir /etc/sudoers.d`?: check `sudo -l`)
- `openSUSE-release-appliance-openstack` vs `-kvm` having no side effects for a Hetzner (KVM) guest
