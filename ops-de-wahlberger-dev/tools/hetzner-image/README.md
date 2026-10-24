# Tumbleweed image for Hetzner Cloud (built in rescue mode)

`build-in-rescue.sh` runs inside Hetzner's **rescue system** (Debian, root, x86_64) and
writes the official openSUSE Tumbleweed **Minimal-VM kvm-and-xen** image (GPT with BIOS-boot
partition, BTRFS root with snapper) onto the server's disk, grows it to the full disk and
makes it reachable over SSH. You then snapshot the disk and create servers from that snapshot.

Why this exists: Hetzner offers no Tumbleweed image, and this image has **no cloud-init**, so
the SSH key / user-data you give `hcloud server create` is **ignored**. Everything needed to log
in is therefore injected offline by the script.

## What the script does

1. Guard rails: root only; rescue-system heuristic (hostname `rescue`, `/root/.oldroot` or
   "rescue" in `/etc/motd`; `--skip-rescue-check` overrides only this); target must be a
   **whole disk** block device, 30-50 GB, nothing mounted or swapped on it; `--yes` required
   (`--dry-run` previews and changes nothing, not even `apt`).
2. Installs missing tools with apt (`qemu-utils gdisk btrfs-progs parted util-linux curl`).
3. Downloads the pinned image and requires three SHA256 values to agree: the value pinned in the
   script (copied from the mirror's `.sha256` on 2026-10-11), the mirror's `.sha256` fetched now,
   and the downloaded file.
4. `qemu-img convert -O raw` onto the disk (after zeroing the first/last 16 MiB), `sgdisk -e`,
   grows the partition of GPT type "Linux x86-64 root" to the end of the disk (start sector and
   PARTUUID kept), mounts it, `btrfs filesystem resize max`.
5. Injects (all measured against the image, see `RESULTS.md`):
   - user `erikwahlberger`, uid 1000, group `users` (gid 100; the image has no `wheel`),
     `/bin/bash`, password `*` (locked), `~/.ssh/authorized_keys` from `--pubkey-file`
     (0700/0600, numeric owner 1000:100);
   - `/etc/sudoers.d/erikwahlberger` (`NOPASSWD:ALL`, 0440);
   - **the image ships without `sudo`**: `bootstrap-sudo.service` installs it with zypper on first
     boot (needs outbound internet; retries every 30 s; takes about 1 minute). Until it finishes,
     `sudo` does not exist. Wait for `command -v sudo` before running the playbook;
   - `/etc/ssh/sshd_config.d/10-bootstrap-key-only.conf` (`PasswordAuthentication no`);
   - hostname `ops`, `sshd.service` enabled;
   - the **jeos-firstboot wizard is skipped** by deleting `/var/lib/YaST2/reconfig_system`
     (the unit's `ConditionPathExists`). Its other jobs (locale, timezone, root password,
     snapshot "after jeos-firstboot configuration") are not needed: locale `en_US.UTF-8`,
     timezone UTC and a locked root are the image defaults; the playbook sets the rest;
   - no account keeps a usable password (root is `*`; anything else would be forced to `*`);
   - no SSH host keys and no machine-id are baked in (each server generates its own);
   - `/etc/selinux/.autorelabel` (the image is SELinux **enforcing**; files written from the
     rescue system are unlabeled and are relabeled on the first boot).
6. `umount`, `sync`, `btrfs check --readonly`, summary. It never boots, reboots or powers off.

## Owner workflow (hcloud; NOT run or verified by the author)

```sh
# 0. A throwaway builder with the SAME disk size as the final server (CX23, 40 GB, x86_64).
hcloud server create --name hz-builder --type cx23 --image debian-12 --location nbg1 \
  --ssh-key <your-hcloud-ssh-key-name>
# 1. Rescue mode, then reboot into it (prints a root password unless you pass --ssh-key).
hcloud server enable-rescue --type linux64 --ssh-key <your-hcloud-ssh-key-name> hz-builder
hcloud server reset hz-builder
# 2. Copy the script and the PUBLIC key (single ssh-ed25519 line), preview, run.
IP=$(hcloud server ip hz-builder)
scp build-in-rescue.sh ~/.ssh/id_ed25519.pub root@"$IP":/root/
ssh root@"$IP" 'cd /root && ./build-in-rescue.sh --pubkey-file id_ed25519.pub --dry-run'
ssh root@"$IP" 'cd /root && ./build-in-rescue.sh --pubkey-file id_ed25519.pub --yes'
# 3. Power off (the disk is clean after the script), snapshot, delete the builder.
hcloud server poweroff hz-builder
hcloud server create-image --type snapshot --description "tumbleweed-ops-$(date +%F)" hz-builder
hcloud image list --type snapshot          # note the image ID
hcloud server delete hz-builder
# 4. Create the real server from the snapshot (no cloud-init: --ssh-key has no effect).
hcloud server create --name ops --type cx23 --image <snapshot-id> --location nbg1
ssh erikwahlberger@<ip>                     # use the web console if this fails
```

The builder must never boot the written system before the snapshot: a first boot generates SSH
host keys and a machine-id (the script leaves none) and runs `bootstrap-sudo`, which would then be
baked into every server created from the snapshot. A snapshot cannot be used on a server type with a
smaller disk; a larger disk is not grown automatically (the partition ends at 40 GB).

Image pin: Tumbleweed removes old snapshot files from the mirror. If the pinned URL returns 404,
choose the current `...-kvm-and-xen.qcow2` (not `-grub-bls`/`-sdboot`: UEFI only; not `-Cloud`:
XFS) and re-run with `--image-url URL --sha256 HEX`; repeat the test in `RESULTS.md` before trusting it.

## Tests (in this directory)

- `test/assert-offline.sh /dev/loopN pubkey`: modes, owners, contents on the produced disk.
- `test/boot-test.sh disk.raw key outdir`: boots a copy in `qemu-system-x86_64` (SeaBIOS, TCG)
  and probes it over SSH. Results: `RESULTS.md`.

The container test uses `--allow-loop` on a loop device backed by a 40 GB sparse file. That flag
(and `--skip-rescue-check`) must never be used on a real server.
