# Test results (2026-10-11)

Everything below was measured with **qemu x86_64 TCG, SeaBIOS (not Hetzner)** on an arm64 macOS
host, from a copy of a disk produced by `build-in-rescue.sh` inside a privileged `debian:12`
(aarch64) Docker container, with a 40 GB sparse file on a loop device standing in for `/dev/sda`
(`--allow-loop`). The test used its own throwaway ed25519 key, never the owner's.
Image: `openSUSE-Tumbleweed-Minimal-VM.x86_64-1.0.0-kvm-and-xen-Snapshot20261009.qcow2`,
sha256 `3645b623...d9df07` (mirror `.sha256`, pinned value and file agree).

## A. Image inspection (offline, read-only)

| Finding | Evidence |
|---|---|
| GPT: p1 2 MiB EF02 `p.legacy`, p2 512 MiB EF00 `p.UEFI`, p3 23.5 GiB type 8304 (`4F68BCE3-...` Linux x86-64 root) `p.lxroot`; btrfs label `ROOT` | `sgdisk -p`, `blkid` |
| **Real root is the btrfs *default subvolume* `@/.snapshots/1/snapshot` (ID 258), not `@`.** Mount without `subvol=`; other subvols (`@/var`, `@/home`, ...) come from the image's `/etc/fstab` | `btrfs subvolume get-default`, fstab |
| jeos-firstboot is `WantedBy=default.target`, guarded by `ConditionPathExists=/var/lib/YaST2/reconfig_system` (file lives in subvol `@/var`). `jeos-firstboot-snapshot.service` has the same condition and deletes it. The wizard is fully interactive (locale, keymap, EULA, timezone, root password, user, network) | unit files, `/usr/sbin/jeos-firstboot` |
| Deleting that flag file skips the wizard | boot test C |
| **No `sudo` in the image** (no `/usr/bin/sudo`, no sudoers); `su` and `run0` exist, no polkit | `ls` |
| root password field is `*`; no other login account; group `users` gid 100; **no `wheel` group** | `/etc/shadow`, `/etc/group` |
| sshd.service already enabled; host keys not baked in; `Include /etc/ssh/sshd_config.d/*.conf` first; sshd defaults would allow passwords (none exist) | image files, `sshd -T` |
| NetworkManager enabled (DHCP on any wired NIC by default), firewalld enabled | `multi-user.target.wants` |
| SELinux enforcing/targeted, `selinux=1 security=selinux` on the cmdline, `/etc/selinux/.autorelabel` already present; autorelabel generator relabels at boot | `/etc/selinux/config`, generator |
| `/etc/locale.conf` `LANG=en_US.UTF-8`, `/etc/localtime` -> UTC, no `/etc/hostname`, no `/etc/machine-id` | image files |
| GRUB `console=ttyS0,115200 console=tty0` | `/etc/default/grub` |

## B. Script behaviour (container, loop device)

- `shellcheck -x` clean for the script and both test scripts.
- Refusals verified: no `--yes`; target not a block device; target a partition; loop device
  without `--allow-loop`; pubkey file with several lines; bad `--sha256`; non-rescue environment
  (with a `uname` shim to pass the x86_64 check); `--dry-run` changes nothing (mirror `.sha256`
  matches pinned).
- Full run (twice, the second time on the already written disk): `rc=0`, the image is written,
  GPT backup header relocated (`sgdisk -v`: no problems), partition 3 ends at the last usable
  sector (83886046), `btrfs filesystem resize max` -> 39.50 GiB, `btrfs check --readonly`: no errors.
- `test/assert-offline.sh`: 23 PASS, 0 FAIL (modes/owners/contents: `.ssh` 700, `authorized_keys`
  600, both 1000:100 and equal to the pubkey; sudoers 440 root:root; passwd/shadow lines; shadow
  stays `root:kmem 640`; no usable hash; hostname; sshd and bootstrap-sudo enabled; flag removed;
  no host keys; machine-id empty).
- Note: the last edit (the `--skip-rescue-check` flag) was only checked with `--dry-run` and
  `shellcheck`; the full run before it is what the numbers above come from.

## C. Boot test (qemu TCG, SeaBIOS; `-m 2048 -smp 2`, virtio disk and virtio-net, user networking)

Booted from a copy of the produced disk with **BIOS** (`/sys/firmware/efi` absent). Run twice
(before and after adding the sshd drop-in), both identical apart from `PasswordAuthentication`.

- SSH answers 103 s after qemu start (TCG); no wizard on the console; serial console shows the
  login prompt `ops login:` and `ens3: 10.0.2.15`.
- `ssh -p 2224 erikwahlberger@127.0.0.1` with the throwaway key: works. `id`: uid 1000, gid 100 `users`.
- `sudo -n true`: works **only after** `bootstrap-sudo.service` installed `sudo-1.9.17p2` with
  zypper over the network (about 55 s after sshd came up; the unit took 1 min 11 s). Before that,
  `sudo` did not exist.
- `df -h /`: `/dev/vda3 40G 714M 39G`; `findmnt -no FSTYPE /` = `btrfs`, subvol `/@/.snapshots/1/snapshot`
  (rw, seclabel, discard=async); `btrfs filesystem show`: 39.50 GiB.
- `snapper list-configs`: `root /`; `snapper list`: #1 "first root filesystem" (current), plus
  pre/post #2/#3 created by the zypper run.
- `/etc/os-release`: `openSUSE Tumbleweed` (kernel 7.2.9-1-default).
- SELinux: **enabled, enforcing** (config enforcing, policy targeted). Injected files were relabeled
  on first boot (`ssh_home_t` on `.ssh` and `authorized_keys`, `.autorelabel` removed afterwards).
  sshd key login worked in enforcing mode.
- Network: NetworkManager "Wired connection 1" on `ens3` activated by DHCP (10.0.2.15/24, default via
  10.0.2.2; qemu SLIRP). NIC is `ens3` (not `eth0`) here.
- Accounts with a usable password hash (`awk` over `/etc/shadow`): none. `sshd -T`:
  `PermitRootLogin prohibit-password`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`
  (without the drop-in: both `yes`, harmless with locked passwords).
- `systemctl --failed`: empty. `systemctl is-active jeos-firstboot jeos-firstboot-snapshot bootstrap-sudo`:
  `inactive` x3 (jeos: "ConditionPathExists=/var/lib/YaST2/reconfig_system was not met"; bootstrap-sudo:
  condition `!/usr/bin/sudo` no longer met after install). `sshd`, `NetworkManager`, `firewalld`: active.
- firewalld: zone `public` on `ens3`, services `dhcpv6-client ssh`.
- `/etc/hostname` = `ops`; machine-id and SSH host keys (ed25519, ecdsa, rsa, mldsa44-ed25519)
  generated at first boot; timezone Etc/UTC; locale `en_US.UTF-8`, keymap unset.
- Journal warnings worth knowing: `dev-combustion-config.device` times out after about 20 s at boot
  (combustion looks for a config drive; harmless, costs ~20 s), `BTRFS warning: qgroup marked inconsistent,
  qgroup inherit needs a rescan` after the zypper snapshot, chronyd stepped the clock (TCG).

## D. NOT verified (needs real Hetzner)

- That `looks_like_rescue` matches Hetzner's rescue system (hostname `rescue` / `/root/.oldroot` /
  motd text are from memory); fall back to `--skip-rescue-check`.
- Booting on Hetzner hardware: legacy BIOS/CSM from a snapshot, virtio NIC name (here `ens3`, the
  playbook may assume `eth0` or `ens3`), DHCP with Hetzner's /32 + link-local gateway, IPv6 (SLAAC vs
  the static address Hetzner shows), outbound access for `bootstrap-sudo` (zypper to
  `download.opensuse.org`), real console output.
- All `hcloud` commands in `README.md`; that a snapshot of a never-booted disk behaves like the test copy.
- The `apt-get install` branch of the script (all tools were already installed in the test container, so only the "nothing missing" path ran).
- Timing on real hardware (the container run took 6 s for write+grow+inject on a local loop device).
