# restic_backup

Daily [restic](https://restic.net/) backup of the ops VM's Semaphore state to
the append-only restic REST server on `nas.de.int.wahlberger.dev` (its
`restic_server` role), repository `ops`, via a systemd timer. The timer runs
independently of Ansible and Semaphore: a backup must not depend on the thing
it protects being reachable.

Adapted from the former cloud host's role of the same name (Debian, one live
`/opt/podman` copy, retention on the client). This version differs on purpose:

| | cloud | ops VM |
|---|---|---|
| Package manager | apt | zypper |
| What restic reads | live `/opt/podman` | one staging directory with a consistent SQLite copy |
| Retention | `restic forget --prune` possible | none, ever; the NAS applies it |
| Schedule | 04:30 | 05:00 (`restic_backup_on_calendar`) |
| Repository | `cloud` | `ops` |

## What a run does

1. For each entry in `restic_backup_sqlite_databases` it runs
   `sqlite3 -readonly <src> ".backup '<staging>/<name>.partial'"`, verifies the
   copy with `PRAGMA integrity_check`, sets mode `0600` and renames it over the
   previous copy. Why not copy the file: Semaphore's database is in WAL mode,
   so committed data may exist only in the `-wal` file, and a plain copy can be
   torn or stale. `.backup` produces one complete, self-contained file. The
   `-wal`/`-shm` files are never copied and are excluded.
2. `restic backup` of `restic_backup_staging_dir` only.
3. One `restic check --read-data-subset=10%` (covers SH-FR-82 and SH-FR-152).
   Any failing step ends the script non-zero.
4. If the Resend credentials are present (`restic_backup_notify_on_success`),
   a summary email.

A failing run triggers `OnFailure=notify-failure-immediate@%n.service`, which
mails the owner within seconds (SH-FR-83, well inside the 10 min bound). The
NAS freshness check (26 h) is the second line of defence.

## What is kept out of every backup (SH-FR-80, 151, 171)

`config.json`, every `*.env` file (including the restic env file) and
`identity.secret` are out because (a) restic reads nothing but the staging
directory by default and (b) `restic_backup_exclude` repeats the patterns as a
second layer if someone adds a path to `restic_backup_paths`. The rendered
script covers both. The restic env file
lives in `restic_backup_env_dir`, a different directory from the staging
directory.

## Retention: none here

The script has no `forget` or `prune` step and the role fails when
`restic_backup_forget_enabled` is true. The repository is append-only for this
host; retention and pruning run on the NAS (`restic-server-maintenance`).
Because the staging directory holds exactly the latest copy, a deleted
Semaphore project is still restorable from older snapshots until the NAS
prunes them.

## `Environment=HOME=/root`

systemd services have no `$HOME`; restic needs one to find its cache and fails
with `unable to locate cache directory` otherwise. The service runs as root.

## Secrets

- `vault_restic_backup_repo_password`: encrypts every backup. Losing it makes
  every backup unrecoverable. Keep a copy in 1Password (the 1Password item for
  this repo), not only in Vault.
- `vault_restic_backup_rest_server_password`: the htpasswd password of user
  `ops` on the NAS. New value, not the cloud's.

The NAS holds the repository password but never `access_key_encryption` or the
ZeroTier identity (SH-BR-11, SH-FR-171).

## Restoring

```sh
export $(grep -v '^#' /var/lib/restic-backup/restic-backup.env | xargs)
restic snapshots
restic restore latest --target /tmp/restore   # semaphore.sqlite inside
```

Stop the Semaphore container, copy `semaphore.sqlite` to
`<semaphore_data_dir>/data/database.sqlite` with mode `0600` and owner
`semaphore_uid`, start the container.

