# restic_server

## Purpose

Runs restic's REST server (`rest-server`) as the Podman Quadlet
`restic-server` (unit `restic-server.service`, deployed through the `container`
role). It is the backup target for `cloud-wahlberger-dev`: the cloud host
pushes its restic repository here over HTTP. The server runs `--append-only` and
`--private-repos`, so a compromised client can add data but not delete it, and
sees only its own repository.

The role creates the `restic-server` system account, the repository directory,
the bcrypt `.htpasswd` and the container. The maintenance run that applies
retention is part of the same role (see "Maintenance" below).

## Role variables

All variables, their defaults and constraints are in `defaults/main.yml` and
`meta/argument_specs.yml`. Required, with no usable default:

- `restic_server_clients`: list of `{username, password}`, one per backup client.
  The role fails before any change if the list is empty or a password is empty.
  Production has one entry, `cloud`. Source the password from the Vault:

  ```yaml
  restic_server_clients:
    - username: cloud
      password: "{{ vault_restic_server_cloud_htpasswd_password | default('') }}"
  ```

- `restic_server_maintenance_repo_password`: the encryption password of the
  cloud repository (`vault_restic_server_cloud_repo_password`). Empty fails the role.
- `restic_server_allowed_sources`: list of CIDRs (production `10.10.0.0/16`
  home LAN and `10.243.0.0/16` ZeroTier). This role opens nothing itself; the
  production `firewall_rich_rules` are built from this list.

Two shared secrets must equal the cloud playbook's values (BD-BR-09):
`vault_restic_server_cloud_htpasswd_password` equals cloud's
`vault_restic_backup_rest_server_password`, and
`vault_restic_server_cloud_repo_password` equals cloud's `vault_restic_backup_repo_password`.

## Network and firewall

`restic-server` uses `Network=host` and `--listen :<restic_server_port>`, with no
`PublishPort=` and no Caddy network (spike `tests/spikes/A-05-firewall-podman.md`).
A published port is DNATed and takes firewalld's FORWARD path, which zone rich
rules do not filter. With host networking the traffic is INPUT, so the rich rules
(one per allowed source: `rule family="ipv4" source address="<CIDR>" port
port="8000" protocol="tcp" accept`) are the only gate, and `8000/tcp` must never
be added to `firewall_allowed_ports` or a firewalld service. The listener binds
every interface; firewalld is the only access control. This is unverified until
BD-AC-45 passes on the VM.

## Repository location (DOC-O12, BD-D-08)

Repositories live in `restic_server_data_dir`, by default `/mnt/data/restic-repos`:
a plain directory (owner `restic-server`, mode `0700`) inside the `@data`
subvolume, outside `samba_data_dir` and not on the backup disk.

- The `:Z` bind mount relabels this directory only, so Samba's SELinux context
  is untouched. That is why it is a dedicated directory and not below `samba/`.
- The existing snapper `data` config snapshots it (`.snapshots`), and btrbk
  copies `@data` to the backup disk. Both are the recovery sources after a wrong
  prune; they preserve file mtimes when copied back with `cp -a` or `rsync -a`.
- To move it, override `restic_server_data_dir`. The role asserts that the path is
  below `restic_server_mount_path` (a `storage_mounts` path, default `/mnt/data`)
  and not at or below `samba_data_dir`, `<mount>/.snapshots` or the btrbk
  snapshot directory (BD-FR-97), and fails before any change otherwise.

The role also reads the live mount table first and fails before any change, naming the path,
when `restic_server_mount_path` is not mounted from its `storage_mounts` subvolume (BD-FR-25).
`restic-server.service` itself mails through `notify-failure@%n` (5 failures in 10 minutes),
because `Restart=always` would otherwise send one mail per restart of a crash loop.

## Risk statement (DOC-O9, BD-BR-10)

The NAS holds the encryption password of the cloud repository (needed by the
maintenance run). Root on the NAS can therefore read the contents of the cloud
backups. The owner accepts this risk.

## Passwords and htpasswd

Each client password is hashed with bcrypt into `<data_dir>/.htpasswd` (mode
`0600`, owner `restic-server`) by `community.general.htpasswd`, which needs the
`python3<minor>-passlib` and `python3<minor>-bcrypt` packages for Ansible's
interpreter (Python 3.13+ has no `crypt` module, so passlib needs the bcrypt
backend); the role installs both with zypper and checks them with `rpm -q`. A changed password restarts rest-server,
so the new one authenticates and the old one gets HTTP 401 within seconds. No
client or repository password is written to the Quadlet or to `/etc/systemd/system/`.
A client removed from the list stays in `.htpasswd`; delete its line by hand.

## Maintenance

`restic-server-maintenance.timer` (`OnCalendar=*-*-* 06:00:00`, `Persistent=true`, `RandomizedDelaySec=5min`)
starts `restic-server-maintenance.service`, a oneshot that runs
`/usr/local/bin/restic-maintenance.py` as `restic-server` (User/Group, so every
file it creates is owned by that account). The role installs `restic` with zypper.
It waits for the `/mnt/data` mount and mails through `notify-failure-immediate@%n`
on failure. The repository password is in `/etc/restic-server-maintenance.env`
(`0600 root:root`, `RESTIC_PASSWORD=`), which systemd reads as root; it is in no
unit file. Order in the script: the repository must exist (it never runs
`restic init`), the prune guard, `forget --dry-run --json` with the keep values (re-listing
snapshots afterwards), `forget <explicit IDs>`, `prune`, then
`check --read-data-subset`.

After a successful run the maintenance service restarts `restic-server.service`
(`ExecStartPost=+systemctl try-restart`; the `+` runs it outside the unit's
sandbox). rest-server counts its `--max-size` usage at start, and the out-of-band
prune would otherwise leave that counter stale. A failed run does not restart it.

Prune guard (BD-BR-07): a client can record any snapshot time, which would make
retention drop genuine snapshots. The script compares each snapshot's recorded
time with the mtime of its file in `<repo>/snapshots/` (set by the NAS). If any
is more than `restic_server_maintenance_max_time_skew_hours` (6) after it, or more
than 48 h before it (script `--max-past-hours`, for long backups), it
lists the IDs, runs neither forget nor prune and the service ends `failed`.
Only the IDs the dry run would remove are forgotten, and only if all were in the
guarded list and the list is unchanged after the dry run (a snapshot forged
meanwhile aborts the run with exit 3, nothing deleted).

- DOC-O6, stale lock: `sudo -u restic-server env RESTIC_REPOSITORY=<data_dir>/cloud
  RESTIC_PASSWORD=... restic unlock` (as the service account, so no root-owned
  files appear). Read the password from the env file with `sudo`.
- DOC-O8, guard tripped: `journalctl -u restic-server-maintenance` lists the
  offending IDs. Inspect them (`restic cat snapshot <id>`); remove forged
  snapshots by hand by deleting their files in `<data_dir>/cloud/snapshots/`
  after confirming they are not genuine, then start the service again.
- DOC-O10, re-baselining after a restore or copy that changed mtimes: set each
  snapshot file's mtime to its recorded time, e.g.
  `sudo -u restic-server touch -d "<time from restic snapshots --json>" <data_dir>/cloud/snapshots/<id>`.

## Does not do

- It does not open the firewall: `firewall_rich_rules` (firewall role) does, built from `restic_server_allowed_sources`.
- It does not initialise repositories: the client runs `restic init`, and the maintenance run never does.
- It does not provide TLS. The data is encrypted client-side; only the htpasswd
  credential travels in clear, and the port is reachable from the LAN and
  ZeroTier only.
- It does not set the Samba SELinux context or touch `samba_data_dir`.
- It does not delete data in normal operation: only the maintenance run and the
  owner by hand remove snapshots (BD-BR-06).
