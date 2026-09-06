# restic_backup

Nightly [restic](https://restic.net/) backup of this NAS's Samba share and
all container data to `pi-de-int-wahlberger-dev`'s `restic_server` role, via
a systemd timer (not orchestrated through Ansible/Semaphore itself — the
timer runs independently of whether/when the playbook is re-applied). Meant
to be the *permanent* backup target, not just a stopgap, until a second
drive is added to this NAS and/or a Hetzner Storage Box is added as a
further target.

## `Environment=HOME=/root` — why it's needed

systemd services run with a minimal environment: no `$HOME`, no
`$XDG_CACHE_HOME`. restic needs one of those to locate its local metadata
cache, and fails with `unable to locate cache directory` without it — the
repository itself still gets created fine (that step doesn't need the
cache), so the failure only shows up on the very next restic command. The
service runs as root (no `User=` set), so `HOME=/root` is correct here.

## What's backed up, and what isn't

`restic_backup_paths` covers the whole Samba share (`samba_mount_path`) and
`/mnt/containers` (every service's data) — but the raw Paperless-ngx
Postgres data directory is excluded (`restic_backup_exclude`). A live
filesystem copy of a Postgres data directory mid-write isn't guaranteed
restorable. Instead, the backup script runs `pg_dump` into
`restic_backup_staging_dir` first, and that consistent dump file is what
actually gets backed up. Mealie needs no equivalent treatment — it uses an
embedded SQLite database, not a separate Postgres container.

`.snapshots` (Snapper's own Btrfs snapshot history, wherever it appears
under a backed-up path) is also excluded. Backing it up would mean restic
redundantly versioning Snapper's own historical versions on top of its own
versioning, and — worse — Snapper rotates (creates/deletes) those snapshots
on its own schedule, independently of restic's directory walk, which
produces `incomplete metadata ... no such file or directory` errors for
files that vanish mid-backup when Snapper deletes a snapshot restic is still
reading.

## Why a systemd timer, not a Semaphore-scheduled Ansible run

The backup itself (dump + `restic backup` + `restic forget --prune`) is a
data-plane operation that runs every night regardless of whether Ansible
runs that day — it shouldn't depend on Semaphore being reachable. Ansible's
job here is only to *deploy* the script, environment, and timer
idempotently; a native systemd timer is what actually triggers it, matching
this repo's general preference for native OS mechanisms over reimplementing
scheduling in Ansible/Semaphore.

## Secrets — and one that also needs a copy outside Vault

Two secrets, both in this playbook's Vault:

- `vault_restic_backup_repo_password` — encrypts every backup. **Losing
  this makes every backup permanently unrecoverable.** Keep a copy
  somewhere durable outside Ansible Vault too (e.g. 1Password) — if you
  ever lose both the Vault password and this, Vault itself can't help you
  recover it.
- `vault_restic_backup_rest_server_password` — the REST server's htpasswd
  password. This is a **shared secret**: it must be the exact same value as
  `pi-de-int-wahlberger-dev`'s `vault_restic_server_htpasswd_password`.
  Generate it once, put it in both playbooks' Vaults.

## Restoring

From this host (or any host with `restic` and the same `RESTIC_REPOSITORY`/
`RESTIC_PASSWORD`):

```sh
export $(grep -v '^#' /var/lib/restic-backup/restic-backup.env | xargs)
restic snapshots
restic restore latest --target /tmp/restore
```

Paperless-ngx's data comes back as `paperless.sql` inside the restored
tree — restore it with `psql` (or `podman exec -i paperless-db psql -U
paperless paperless < paperless.sql` after stopping the app container),
not by copying files into the live Postgres data directory.
