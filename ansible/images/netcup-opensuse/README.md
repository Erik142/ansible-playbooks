# Tumbleweed image for netcup VPS (KIWI)

KIWI description for an openSUSE Tumbleweed x86_64 raw disk image for the netcup VPS. It is the
netcup variant of `../image/` (Hetzner). Same btrfs, snapper, BIOS+UEFI hybrid boot and SELinux
setup. The differences: no cloud-init, and the admin account, its SSH key and the sshd policy are
baked into the image, because netcup has no metadata service.

**Status: validated statically only, never built, never booted.** See "UNVERIFIED" below.

## What you get

| Item | Value |
|---|---|
| Root filesystem | BTRFS with snapper snapshot root, as in the Hetzner variant |
| Boot | GPT, BIOS boot partition + 512 MB ESP, grub2 |
| SELinux | enforcing, targeted; full relabel once in the first-boot initrd |
| Network | NetworkManager, DHCP (UNVERIFIED for netcup) |
| Admin account | `erikwahlberger`, group `wheel`, password locked, sudo `NOPASSWD`, authorized key from `--ssh-pubkey` |
| Root account | locked (`passwd -l root`) |
| sshd | `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin no`, `AllowUsers erikwahlberger` |
| Root growth | `dracut-kiwi-oem-repart` on first boot, fills the disk |
| Not included | cloud-init, LUKS (disk is unencrypted), firewalld (`firewall` role handles it), ZeroTier (`zerotier` role) |

## Build

```sh
./build.sh --ssh-pubkey ~/.ssh/id_ed25519.pub --engine docker   # sudo if not in the docker group
```

The public key is written to `/etc/netcup-admin-authorized-keys` inside the build, installed as
`authorized_keys` for `erikwahlberger` in `config.sh`, and removed again. Only the public key is
used; no private material goes into the image or the repo. The result is `out/<name>.raw.xz` plus a
`.sha256`. Decompress before upload if netcup needs a raw file.

Upload: netcup SCP panel, custom image. Verify netcup's accepted format (`.raw` or `.qcow2`) in
their docs before uploading.

## Changes vs `../image/`

- `config.kiwi`: profile `Netcup`, image name `openSUSE-Tumbleweed-Netcup`, cloud-init and the
  Hetzner datasource removed, `sudo` added to the image packages.
- `config.sh`: cloud-init enable block removed; admin user, key install, sudoers drop-in added.
- `root/etc/ssh/sshd_config.d/10-netcup-key-only.conf`: sshd policy (replaces the Hetzner
  overlay and the cloud-init datasource overlay).
- `build.sh`: profile `Netcup`, required `--ssh-pubkey FILE`, key injected at build time.
- `test/` (cloud-init boot test) not carried over. A netcup boot test is still to write.

## UNVERIFIED until built and booted

- The image builds (needs an x86_64 Linux host with loop devices, not Docker Desktop on macOS).
- DHCP works on netcup. If netcup needs a static network config, add it under
  `root/etc/NetworkManager/system-connections/`.
- The `openSUSE-release-appliance-openstack` package is kept from the Hetzner variant. Check
  whether a KVM-flavoured release package is more correct.
- `dracut-kiwi-oem-repart` grows the btrfs root on a netcup disk, including the BIOS boot partition.
- SELinux relabel runs on first boot, and the admin login works with the baked key.
- sudo works for `erikwahlberger` (check `sudo -l` after login).
