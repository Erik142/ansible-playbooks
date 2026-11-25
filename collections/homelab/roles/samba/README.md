# samba

Native Samba file server (`smbd`/`nmbd` as openSUSE system services — **not**
a Podman container, unlike rpi-karlsruhe's `dockurr/samba` image) with a
single **guest-only** share: no Samba user accounts, no password, anyone who
can reach the host on the network can read and write.

## Role variables

| Variable | Default | Description |
|----------|---------|-------------|
| `samba_mount_path` | `/mnt/data` | The mounted disk holding Samba data — must already be a mountpoint. |
| `samba_data_dir` | `{{ samba_mount_path }}/samba` | Fixed subdirectory under the mount holding all Samba data. |
| `samba_share_name` | `share` | Name of the SMB share (`\\nas\<name>`), and of its subdirectory under `samba_data_dir`. |
| `samba_share_path` | `{{ samba_data_dir }}/{{ samba_share_name }}` | Full path to the share directory. |
| `samba_share_comment` | `NAS file share (guest access)` | Comment shown to clients. |
| `samba_server_string` | `nas.de.int.wahlberger.dev` | Samba server string. |
| `samba_guest_account` | `nobody` | Unix account guest connections are mapped to. |
| `samba_selinux_type` | `samba_share_t` | SELinux type label applied to `samba_data_dir` when SELinux is enabled. |

## Guest access — know the tradeoff

`guest only = yes` means the share accepts **every** connection anonymously;
there is no way to also require a password for some users without adding a
real Samba user (out of scope here — this was a deliberate choice for
simplicity). Anyone on the same network segment as this host can read and
write. Keep this host off any network segment you don't trust, or restrict it
at the router/VLAN level — the `firewall` role only controls which hosts can
reach *this* NAS, not what a connected LAN client is allowed to do once in.

## SELinux

Recent openSUSE Tumbleweed snapshots default to SELinux (targeted policy)
rather than AppArmor. Its policy doesn't know about custom share paths
outside Samba's usual defaults — an unlabeled path fails with
`canonicalize_connect_path failed` in `journalctl -u smb`, even though POSIX
permissions (`0777` above) are wide open, because SELinux denies the access
before Samba's own permission checks ever run. The role labels both
`samba_mount_path` (the mountpoint itself, non-recursively) **and**
`samba_data_dir` (recursively, below it) with `samba_selinux_type`
(`community.general.sefcontext` + `restorecon`), unconditionally — a no-op if
SELinux isn't enabled — so this isn't something you have to remember to redo
after a fresh OS install.

Both are needed: SELinux requires *search* permission on every directory
component of a path, not just the final one. A freshly mounted filesystem's
root is `unlabeled_t` until something explicitly labels it — check
`sudo ausearch -m avc -ts recent` for `denied { search }` entries naming your
mount's device if the share still won't connect; a denial on the mountpoint
itself (not `samba_data_dir`) is exactly this "one level up" gap.

On top of the explicit labeling above, the role also enables the
`samba_export_all_rw` boolean, which tells `smbd` to ignore per-file SELinux
types on exported shares entirely. This matters because Podman's own SELinux
separation keeps relabeling `paperless_ngx_inbox_dir` (a subdirectory of this
share that's also bind-mounted into the `paperless-ngx` container) back to
`container_file_t`, fighting the `samba_share_t` label set above — rather
than chase Podman's exact relabeling behavior on a path two roles share, the
boolean sidesteps the tug-of-war entirely. Since the share is already
guest-only and world-writable, "security via file labels" wasn't buying
anything here to begin with.

If a future snapshot reverts to AppArmor instead: check `sudo aa-status` and
`journalctl -k | grep -i apparmor` for a `smbd` profile — none ships by
default today, but a future package update could add one.

## macOS compatibility (vfs_fruit)

The share enables `vfs objects = catia fruit streams_xattr` and the global
`fruit:aapl = yes` — the Samba project's own recommended configuration for
macOS clients. Without it, macOS's SMB client falls back to a much chattier
per-file metadata protocol and often creates `._filename` AppleDouble sidecar
files for resource forks; on a large flat directory (thousands of files) this
makes Finder spin for a very long time enumerating it, even though the server
itself is barely working — not a bug in the file transfer, a missing protocol
extension. `catia`/`fruit`/`streams_xattr` ship as part of the standard
`samba` package; if `testparm -s` errors on module load, check
`rpm -ql samba | grep vfs` for the installed VFS module set.

## Inspect on the host

```sh
sudo smbstatus
testparm -s
```
