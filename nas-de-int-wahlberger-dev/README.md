# nas-de-int-wahlberger-dev

Ansible playbook for **`nas.de.int.wahlberger.dev`**, Erik's primary NAS in
Germany, running **openSUSE Tumbleweed**. Serves files over **native Samba**
(guest access, no container), and runs a **Podman Quadlet** container stack
for **Tandoor** and **Paperless-ngx** behind a **Caddy** reverse proxy with
Pocket ID single sign-on. ZeroTier is configured transparently for the whole
LAN at the router, so this host has no ZeroTier client of its own.

Built by copying the conventions of [`cloud-wahlberger-dev`](../cloud-wahlberger-dev),
this repo's reference design — fully-qualified module names, self-contained
roles with documented variables and input validation, idempotent tasks, and
linting wired up — adapted for openSUSE Tumbleweed (`zypper` instead of
`apt`, `firewalld` instead of `ufw`, hand-rolled SSH/fail2ban hardening
instead of `geerlingguy.security`, which doesn't target openSUSE).

## Why this isn't just added to rpi-karlsruhe

This NAS originally replaced `rpi-karlsruhe`'s **same two application
containers** (Mealie, Paperless-ngx) at the **same hostnames** — it's meant to
replace those instances, not sit alongside them as a second copy under
different names. Rather than bolt a second, architecturally different host
(different OS, different container tech conventions, native Samba instead of
containerized) onto an existing playbook, it gets its own reference-quality
playbook. When you cut over, retire the corresponding roles in
`rpi-karlsruhe/main.yml` (`samba`, `paperless-ngx`, `mealie`) yourself.

## Layout

```text
nas-de-int-wahlberger-dev/
├── ansible.cfg                  # project-local Ansible settings
├── site.yml                     # top-level playbook (entry point)
├── backup_disk_init.yml         # one-time backup-disk initialisation (not imported by site.yml)
├── requirements.yml             # Galaxy collections to install
├── .ansible-lint                # lint config (production profile)
├── .yamllint                    # YAML style config
├── README.md / CLAUDE.md        # docs (human / AI agent)
├── reqs/                        # requirements (start at reqs/index.md)
├── tests/                       # render-check.sh, syntax-check-role.sh, spikes
├── inventories/
│   ├── vm/                      # disposable-VM fixture (fake secrets only)
│   └── production/
│       ├── hosts.yml            # host & group *structure* only
│       └── group_vars/
│           └── all/
│               └── vars.yml     # variables for all hosts (vault.yml sits here too)
└── roles/
    ├── common/                  # baseline OS setup (zypper, packages, timezone)
    ├── security/                # SSH hardening, fail2ban, automatic patching
    ├── firewall/                # firewalld host firewall (default-deny inbound)
    ├── podman/                  # Podman + Quadlet runtime
    ├── caddy/                   # reverse proxy + automatic HTTPS (shared network)
    ├── samba/                   # NATIVE Samba file server (not a container), guest access
    ├── tandoor/                 # Tandoor recipe manager, Pocket ID OIDC login
    ├── paperless_ngx/           # Paperless-ngx (Redis + PostgreSQL + app), Pocket ID OIDC login
    ├── forgejo/                 # Forgejo git forge + OCI registry (SQLite), Pocket ID OIDC login
    ├── homepage/                # dashboard linking this NAS's + cloud-wahlberger-dev's services
    ├── backup_disk/             # local backup disk: mount, scrub, smartd, health check (init is a separate playbook)
    ├── btrbk/                   # daily btrbk snapshots + replication to the backup disk
    ├── db_dump/                 # pre-btrbk database dumps
    ├── restic_server/           # restic rest-server (append-only) for cloud-wahlberger-dev
    ├── restic_backup_decommission/  # removes the old NAS-to-Pi restic job
    └── container/                # generic Quadlet (.container) deployer (helper)
```

## Prerequisites

- Ansible (ansible-core ≥ 2.15) on the control machine.
- SSH access to `nas.de.int.wahlberger.dev` as `erikwahlberger` with `sudo`
  rights — escalation is enabled in `site.yml`. **Key-based SSH must work**:
  the `security` role disables password authentication.
- Two storage devices already mounted on the host (this playbook does **not**
  partition/format/mount anything — see "Data layout" below):
  - `/mnt/data` — Samba data (only its `samba/` subdirectory is shared).
  - `/mnt/containers` — container data.
- For the backup feature: a third, empty disk (the backup disk), addressed by
  its `/dev/disk/by-id/` path. It is initialised once by the runbook in
  "Backups" below; `site.yml` never formats it.
- Galaxy collections installed:

  ```sh
  ansible-galaxy collection install -r requirements.yml
  ```

## Usage

```sh
# Dry run — show what would change, with diffs.
/Users/erikwahlberger/.pyenv/versions/ansible-bind9-venv/bin/ansible-playbook site.yml --check --diff

# Apply everything.
/Users/erikwahlberger/.pyenv/versions/ansible-bind9-venv/bin/ansible-playbook site.yml

# Only one role.
/Users/erikwahlberger/.pyenv/versions/ansible-bind9-venv/bin/ansible-playbook site.yml --tags samba
```

The vault password is fetched automatically from 1Password (see `.vault_pass.sh`
and "Secrets with Ansible Vault" below) — no `--ask-vault-pass` needed.

`ansible.cfg` sets `inventories/production/hosts.yml` as the default
inventory, so `-i` is optional.

## Data layout

Persistent data is split across two separately mounted storage devices — each
role **asserts** the mountpoint itself (not a subdirectory of it) is an
actual mountpoint before writing anything, so a missing mount fails loudly
instead of silently landing on the root filesystem:

- `/mnt/data` is the mountpoint; only its `samba/` subdirectory
  (`/mnt/data/samba/`) is shared as the guest Samba share root. Also holds
  Paperless's scan-to-folder inbox at `.../samba/paperless-inbox/`.
- `/mnt/containers/<service>/` — container data (Caddy certs, Tandoor
  data/db, Paperless data/media/export/db/redis).

## Hardening

Baseline hardening runs on every play, before the container runtime:

- **SSH hardening** — root login and password authentication disabled
  (key-only).
- **fail2ban** — bans IPs after repeated failed SSH logins.
- **Automatic patching** — a weekly systemd timer runs `zypper patch`.
  Auto-reboot is **off**; reboot on your own schedule after kernel updates.
- **Host firewall** — `firewalld`, default-deny inbound, allowing only
  SSH / Samba / HTTP / HTTPS. See
  [`roles/firewall/README.md`](roles/firewall/README.md).

See [`roles/security/README.md`](roles/security/README.md) for the
"don't lock yourself out" checklist.

## Services

| Service | How | Notes |
|---------|-----|-------|
| Samba | Native openSUSE service (`smbd`/`nmbd`) | Guest-only share, no user accounts — anyone on the network can read/write. See [`roles/samba/README.md`](roles/samba/README.md). |
| Caddy | Podman Quadlet, custom-built image | Automatic HTTPS via **DNS-01** (Cloudflare) — this host has no public inbound port, so HTTP-01 won't work; creates the shared `caddy.network`. See [`roles/caddy/README.md`](roles/caddy/README.md). |
| Tandoor | Podman Quadlets (app + PostgreSQL), behind Caddy | Pocket ID OIDC login. |
| Paperless-ngx | Podman Quadlets (app + Redis + PostgreSQL), behind Caddy | Pocket ID OIDC login; inbox lives inside the Samba share. |
| Forgejo | Podman Quadlet (rootless, SQLite), behind Caddy | Git forge + built-in container registry at `git.de.int.wahlberger.dev`, Pocket ID OIDC login, git over SSH on port 2222, LAN/VPN only. Registry login uses personal access tokens. See [`roles/forgejo/README.md`](roles/forgejo/README.md). |
| Homepage | Podman Quadlet, behind Caddy | Dashboard linking this NAS's and cloud-wahlberger-dev's services. `rpi-karlsruhe` excluded (legacy). See [`roles/homepage/README.md`](roles/homepage/README.md). |

**Before the first run:** point `recipes.de.int.wahlberger.dev`,
`docs.de.int.wahlberger.dev`, `git.de.int.wahlberger.dev`, and `www.de.int.wahlberger.dev` at wherever
clients actually reach this host (its LAN IP — reachable transparently over
ZeroTier too, via the router) — DNS-01 doesn't need a public IP, unlike
HTTP-01. If migrating the first two hostnames from `rpi-karlsruhe`, do the DNS
cutover only once this playbook has successfully run and you've verified the
new instances.

## Backups

Three layers, all local to this host plus one remote client:

- **btrbk** snapshots `/mnt/data` and `/mnt/containers` daily (`btrbk.timer`,
  01:30) and replicates them to the backup disk, mounted at `/mnt/backup/btrbk`.
  `db_dump` writes consistent database dumps to `/mnt/containers/db-dumps/`
  just before each run. Live Postgres/SQLite files in the snapshots are
  crash-consistent only; the dumps are the restorable copy.
- **restic rest-server** (`restic-server.service`, host networking, append-only,
  quota) serves `cloud-wahlberger-dev`'s backups from `/mnt/data/restic-repos`.
  That directory is part of `@data`, so snapper and btrbk cover it. It is
  reachable only from `10.10.0.0/16` (home LAN) and `10.243.0.0/16`
  (ZeroTier) through firewalld rich rules built from
  `restic_server_allowed_sources`. A daily
  `restic-server-maintenance.timer` (06:00) runs forget/prune/check; the client
  never prunes.
- The old NAS-to-Pi restic job is removed by `restic_backup_decommission`.
  The Pi is **not changed**: its `nas` and `cloud` repositories stay as frozen
  fallbacks.

Details per role: [`backup_disk`](roles/backup_disk/README.md),
[`btrbk`](roles/btrbk/README.md), [`db_dump`](roles/db_dump/README.md),
[`restic_server`](roles/restic_server/README.md). Requirements:
[`reqs/index.md`](reqs/index.md). The host-side render check is
`tests/render-check.sh`; the VM fixture is `inventories/vm/` (never run these
against nas, cloud or the Pi).

### Cut-over flags

Both are in `inventories/production/group_vars/all/vars.yml` and are `false`
at the feature commit, so a normal `site.yml` run changes nothing until the
owner flips them:

| Flag | Set to `true` in | Gates (in `site.yml`) |
|---|---|---|
| `backup_disk_enabled` | step 3 | `backup_disk`, `restic_server`, `db_dump`, `btrbk` |
| `restic_backup_decommission_enabled` | step 5 | `restic_backup_decommission` |

While `restic_backup_decommission_enabled` is `false`, the old restic job
keeps running unchanged. The Pi stays unchanged throughout; nothing in this
playbook connects to it.

### Cut-over runbook (production, not yet executed)

Run from this directory. Each "Do not continue unless" is a hard gate.

**Step 0: VM gate.** Do not continue unless every scenario marked `[V]` in
`reqs/` passes on the VM fixture (`inventories/vm/`) at the commit you deploy
(BD-BR-01).

**Step 1: preconditions.** Do not continue unless all four hold:

```sh
# a) disk size within 1 % of backup_disk_expected_size_bytes (default 6001175126016)
ssh nas lsblk -bdno SIZE /dev/disk/by-id/wwn-0x500003982b7021c1

# b) first and last MiB are zeros (each command must exit 0 and print nothing)
ssh nas sudo cmp -n 1048576 /dev/zero /dev/disk/by-id/wwn-0x500003982b7021c1
ssh nas 'sudo sh -c "tail -c 1048576 /dev/disk/by-id/wwn-0x500003982b7021c1 | cmp -n 1048576 /dev/zero -"'

# c) free space on /mnt/data >= 3x the Pi's cloud repository
ssh pi du -sb /mnt/data/restic-repos/cloud
ssh nas df -B1 --output=avail /mnt/data

# d) used(/mnt/data) + used(/mnt/containers) + Pi cloud repository <= 50 % of the backup disk
ssh nas df -B1 --output=used /mnt/data /mnt/containers
```

For (d) the backup disk size is the value from (a).

**Step 2: initialise the disk.** Review the `--check` output, then run for real
(the confirm value must equal `backup_disk_device`; refusal rules R-01 to R-10
are in [`roles/backup_disk/README.md`](roles/backup_disk/README.md)):

```sh
ansible-playbook backup_disk_init.yml --check -e backup_disk_init_confirm=/dev/disk/by-id/wwn-0x500003982b7021c1
ansible-playbook backup_disk_init.yml -e backup_disk_init_confirm=/dev/disk/by-id/wwn-0x500003982b7021c1
```

**Step 3: mount and enable.** In `vars.yml` set `backup_disk_uuid` to the
printed UUID and `backup_disk_enabled: true`, then:

```sh
ansible-playbook site.yml --tags backup_disk
```

Smoke check: BD-AC-80 row 1.

**Step 4: first btrbk run.** Do not continue unless the fingerprint printed by
the first command equals `btrbk_zypper_repo_gpg_fingerprint`
(`roles/btrbk/defaults/main.yml`):

```sh
osc signkey filesystems | gpg --show-keys --with-fingerprint
ansible-playbook site.yml --tags db_dump,btrbk
ssh nas sudo btrbk -n run
ssh nas sudo systemctl start btrbk.service
```

Do not continue unless `systemctl show -p Result btrbk.service` is
`Result=success` (BD-BR-14: the old job is removed only after the first btrbk
run exited 0). Smoke checks: BD-AC-80 rows 2 to 5.

**Step 5: deploy rest-server, retire the old job.** In `vars.yml` set
`restic_backup_decommission_enabled: true`, then run the full playbook:

```sh
ansible-playbook site.yml
```

Smoke checks: BD-AC-80 rows 6 to 12. Before this step, save
`ls -Zd /mnt/data/samba` (if SELinux is on), the `BTRFS_SCRUB_MOUNTPOINTS`
line, the smartd device lines and `sha256sum /etc/snapper/configs/{data,containers}`
for the row 9 to 12 comparisons.

**Step 6: migrate the cloud repository.** Do not continue unless each check
passes (BD-BR-14).

```sh
# on cloud: stop the client and confirm it is idle
ssh cloud sudo systemctl stop restic-backup.timer
ssh cloud systemctl is-active restic-backup.service      # must print: inactive

# on the Pi: no locks on the repository (RESTIC_PASSWORD = cloud's repo password)
ssh pi restic -r /mnt/data/restic-repos/cloud list locks  # must print nothing

# copy, then fix ownership
rsync -a --numeric-ids pi:/mnt/data/restic-repos/cloud/ nas:/mnt/data/restic-repos/cloud/
ssh nas sudo chown -R restic-server: /mnt/data/restic-repos/cloud

# verify as the service account (password: RESTIC_PASSWORD in /etc/restic-server-maintenance.env)
ssh nas sudo -u restic-server env RESTIC_REPOSITORY=/mnt/data/restic-repos/cloud RESTIC_PASSWORD=... restic --no-cache check --read-data

# snapshot counts must be equal
ssh pi restic -r /mnt/data/restic-repos/cloud snapshots --json | jq length
ssh nas sudo -u restic-server env RESTIC_REPOSITORY=/mnt/data/restic-repos/cloud RESTIC_PASSWORD=... restic --no-cache snapshots --json | jq length
```

`rsync` refuses two remote operands (verified on the VM: "The source and
destination cannot both be remote."), so the copy above cannot be started from a
third machine. Run it on the NAS as root with the destination local
(`rsync -a --numeric-ids pi:/mnt/data/restic-repos/cloud/ /mnt/data/restic-repos/cloud/`);
this needs root SSH from the NAS to the Pi so numeric owners survive.

**Step 7: switch cloud.** Do not continue unless step 6 passed
(`restic check --read-data` exit 0, equal snapshot counts). In
`cloud-wahlberger-dev/inventories/production/group_vars/all/vars.yml` add:

```yaml
restic_backup_rest_server_host: nas.de.int.wahlberger.dev
restic_backup_forget_enabled: false
```

Then, from `cloud-wahlberger-dev/`:

```sh
ansible-playbook site.yml --tags restic_backup
ssh cloud sudo systemctl start restic-backup.service      # one backup + check
ssh nas sudo systemctl start restic-server-maintenance.service
```

This also re-enables cloud's timer (04:30, outside the NAS reboot window
03:00 to 04:00). Smoke checks: BD-AC-80 rows 13 and 14 (row 14 after the next
01:30 btrbk run); the end-to-end acceptance is BD-AC-81.

The cloud and NAS vault keys must match:
`vault_restic_server_cloud_htpasswd_password` equals cloud's
`vault_restic_backup_rest_server_password`, and
`vault_restic_server_cloud_repo_password` equals cloud's
`vault_restic_backup_repo_password`.

### Rollback

- **Cloud back to the Pi:** revert the two step-7 variables in cloud's
  `vars.yml` and run cloud `site.yml --tags restic_backup`. Snapshots taken on
  the NAS after the migration are not on the Pi.
- **NAS back to the old restic job:** `git revert` the feature commit and
  re-run `site.yml`. The Pi's `nas` repository is untouched.
- **Cloud switched before the migration** (it would have created an empty
  repository on the NAS): stop `restic-backup.timer` on cloud, delete
  `/mnt/data/restic-repos/cloud` on the NAS, then redo step 6.
- **Backup disk dead:** `ansible-playbook site.yml --skip-tags backup_disk,btrbk`
  (see [`roles/backup_disk/README.md`](roles/backup_disk/README.md)).

### Capacity and key expiry

- Capacity (BD-A-09, BD-A-16): the repository (quota
  `restic_server_max_size_bytes`, 100 GiB) lives on `@data`, so pruned packs
  are held twice over by snapper `data` snapshots and btrbk copies; step 1
  enforces the 3x and 50 % rules. `disk_space` alerts at 85 % on `/mnt/data`
  and `/mnt/backup/btrbk`.
- The `filesystems` repository signing key expires on **2027-05-07**
  (BD-A-17). Nothing alerts on it; see "Renew the repository key" below.

### Operations and restore

**Restore one file (DOC-O1).** Received snapshots are
`/mnt/backup/btrbk/<source>/<source>.<timestamp>/` (`<source>` is `data` or
`containers`). Copy from the newest suitable one:

```sh
ls /mnt/backup/btrbk/data/
sudo cp -a /mnt/backup/btrbk/data/data.<timestamp>/samba/<path> <destination>
```

**Restore a whole source subvolume (DOC-O2).** Stop the services using it
first. Receive the snapshot onto a btrfs filesystem you can write to (the
received subvolume is read-only), make a writable copy, then move it into place:

```sh
sudo btrfs send /mnt/backup/btrbk/data/data.<timestamp> | sudo btrfs receive <dir-on-a-btrfs-fs>
sudo btrfs subvolume snapshot <dir>/data.<timestamp> <dir>/data-restored
```

To put the restored copy back as the live subvolume, receive it straight into the
top level of the filesystem that holds the source (verified on the VM for `@data`),
rename the broken subvolume away, make a writable snapshot of the received one and
remount. `<uuid>` is the filesystem UUID from `storage_mounts`:

```sh
sudo systemctl stop restic-server.service restic-server-maintenance.timer   # and every other user of the mount
sudo umount /mnt/data
sudo mkdir -p /mnt/top && sudo mount -o subvolid=5 UUID=<uuid> /mnt/top
sudo btrfs send /mnt/backup/btrbk/data/data.<timestamp> | sudo btrfs receive /mnt/top
sudo mv /mnt/top/@data /mnt/top/@data.broken
sudo btrfs subvolume snapshot /mnt/top/data.<timestamp> /mnt/top/@data
sudo umount /mnt/top && sudo mount /mnt/data
sudo btrfs subvolume create /mnt/data/.snapshots && sudo chmod 750 /mnt/data/.snapshots   # snapper's directory is not in the copy
sudo systemctl start restic-server.service restic-server-maintenance.timer
```

Delete `@data.broken` and the read-only `data.<timestamp>` copy only after checking
the result (`btrfs subvolume delete`).

**Restore a database (DOC-O3).** Dumps are in `/mnt/containers/db-dumps/`
(`paperless.sql`, `immich.sql`, `tandoor.sql`, `forgejo.db`); older ones are in
`/mnt/backup/btrbk/containers/containers.<timestamp>/db-dumps/`. Stop the app
container, restore into an empty database, start it again:

```sh
sudo podman exec -i paperless-db psql -U paperless paperless < /mnt/containers/db-dumps/paperless.sql
# Forgejo (SQLite): stop forgejo, then replace the file
sudo cp /mnt/containers/db-dumps/forgejo.db /mnt/containers/forgejo/volume/data/forgejo.db
sudo chown --reference=/mnt/containers/forgejo/volume/data /mnt/containers/forgejo/volume/data/forgejo.db
sudo chmod 600 /mnt/containers/forgejo/volume/data/forgejo.db
```

Container, database and user names per database are `db_dump_postgres` in
`roles/db_dump/defaults/main.yml`. `psql -U <user> <database>` inside the container
needs no password (local socket, verified on the VM); `forgejo.db` must be
chowned to the container's uid after the copy, because the dump is `root:root 600`
and `cp -a` would keep that, which the container cannot read (verified on the VM).

**Restore cloud's data from the NAS repository (DOC-O4).** On cloud, with the
credentials file the `restic_backup` role renders:

```sh
sudo sh -c 'set -a; . /var/lib/restic-backup/restic-backup.env; set +a; restic snapshots; restic restore latest --target /tmp/restore'
```

**Restore from the Pi's frozen `nas` repository (DOC-O5).** Uses the two
restore-only vault keys (`vault_restic_backup_repo_password`,
`vault_restic_backup_rest_server_password`):

```sh
export RESTIC_REPOSITORY='rest:http://nas:<vault_restic_backup_rest_server_password>@pi.de.int.wahlberger.dev:8000/nas/'
export RESTIC_PASSWORD='<vault_restic_backup_repo_password>'
restic snapshots
restic restore latest --target /tmp/restore
```

Read the values with `ansible-vault view inventories/production/group_vars/all/vault.yml`.

**Stale lock (DOC-O6).** As the service account, so no root-owned files appear:

```sh
sudo -u restic-server env RESTIC_REPOSITORY=/mnt/data/restic-repos/cloud RESTIC_PASSWORD=... restic --no-cache unlock
```

**Restore the cloud repository from a snapshot (DOC-O7).** Stop the server and
the maintenance timer, copy back with owner and modification times preserved
(the prune guard compares snapshot-file mtimes), start, then check:

```sh
sudo systemctl stop restic-server.service restic-server-maintenance.timer
sudo rsync -a /mnt/data/.snapshots/<n>/snapshot/restic-repos/cloud/ /mnt/data/restic-repos/cloud/
#   or: from a btrbk copy
# sudo rsync -a /mnt/backup/btrbk/data/data.<timestamp>/restic-repos/cloud/ /mnt/data/restic-repos/cloud/
sudo systemctl start restic-server.service restic-server-maintenance.timer
sudo -u restic-server env RESTIC_REPOSITORY=/mnt/data/restic-repos/cloud RESTIC_PASSWORD=... restic --no-cache check
```

`cp -a` works in place of `rsync -a`. `--delete` is not needed: after a wrong
`forget --prune`, restoring with plain `rsync -a` left the extra newer files in
place and `restic check --read-data` still passed (verified on the VM, BD-AC-54).
The `restic --no-cache` in the `sudo -u restic-server` commands is required: the
service account has no home directory, so restic's default cache directory cannot
be created.

**Prune guard tripped (DOC-O8).** `journalctl -u restic-server-maintenance`
lists the offending snapshot IDs and the service ends `failed` without pruning.
Inspect them with `restic cat snapshot <id>`; delete forged snapshot files in
`/mnt/data/restic-repos/cloud/snapshots/` only after confirming they are not
genuine; then `sudo systemctl start restic-server-maintenance.service`.

**Re-baseline after `restic tag`, `rewrite` or `copy` (DOC-O10).** After
verifying the snapshots, set each new snapshot file's mtime to its recorded
time, then run maintenance:

```sh
sudo -u restic-server touch -d "<time from restic snapshots --json>" /mnt/data/restic-repos/cloud/snapshots/<id>
sudo systemctl start restic-server-maintenance.service
```

**Renew the repository key (DOC-O11).** `btrbk-key-refresh.timer` renews the key
weekly and emails you when it is within 60 days of expiry (2027-05-07) or its
fingerprint changed. When it alerts with the same fingerprint: remove the old
`gpg-pubkey` package, re-run the role so the fingerprint check runs again, and
confirm zypper works:

```sh
sudo rpm -e gpg-pubkey-<id>
ansible-playbook site.yml --tags btrbk
sudo systemctl start btrbk-key-refresh.service
sudo zypper refresh
```

If the key was re-issued with a new fingerprint, verify it with
`osc signkey filesystems | gpg --show-keys --with-fingerprint` before changing
`btrbk_zypper_repo_gpg_fingerprint`.

## Adding a containerized service

Same pattern as `cloud-wahlberger-dev`: create `roles/<svc>/` (underscore, not
hyphen — ansible-lint), put a templated unit at
`roles/<svc>/templates/<svc>.container.j2`, then `include_role: container`
with `container_name` and `container_quadlet_src`. Add `- role: <svc>` to
`site.yml`. See [`roles/container/README.md`](roles/container/README.md).

## Secrets with Ansible Vault

Never commit plaintext secrets. Keep them in an encrypted file alongside the
non-secret vars:

```sh
ansible-vault create inventories/production/group_vars/all/vault.yml
ansible-vault edit   inventories/production/group_vars/all/vault.yml
```

Inside `vault.yml`, name everything with a `vault_` prefix — see
`vault.yml.example` for the exact keys this playbook needs (Paperless's DB
password, both apps' OIDC client secrets, and the Cloudflare DNS API token).
Surface each under a friendly name in `vars.yml` (already done). By default
the vault password is fetched from 1Password automatically — see
`.vault_pass.sh` (requires the `op` CLI signed in and the desktop app
unlocked). Without 1Password, fall back to:

```sh
ansible-playbook site.yml --ask-vault-pass
# or: echo 'my-vault-password' > .vault_pass && ansible-playbook site.yml --vault-password-file .vault_pass
```

**Migrating secrets from rpi-karlsruhe?** Reuse the *existing* values for
`vault_paperless_ngx_db_password`, `vault_paperless_ngx_oidc_client_secret`,
and `vault_cloudflare_dns_api_token` — that hostname, its OIDC client
registration in Pocket ID, and the Cloudflare zone are all unchanged, and a
restored Paperless database dump won't authenticate against a newly
generated DB password. Tandoor (which replaced Mealie at
`recipes.de.int.wahlberger.dev`, see `roles/tandoor/README.md`) deliberately
does **not** reuse Mealie's old Pocket ID client — register a new one and set
`vault_tandoor_oidc_client_secret` instead.

## Linting & validation

```sh
yamllint .
ansible-lint
ansible-playbook site.yml --syntax-check
```

## References

- [Ansible — sample directory layout & best practices](https://docs.ansible.com/ansible/latest/tips_tricks/sample_setup.html)
- [ansible-lint profiles](https://ansible.readthedocs.io/projects/lint/profiles/)
- [Podman Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
- [openSUSE firewalld wiki](https://en.opensuse.org/openSUSE:Firewalld)
- [Samba guest access documentation](https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html)
