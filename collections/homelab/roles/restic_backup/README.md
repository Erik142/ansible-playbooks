# restic_backup

Daily [restic](https://restic.net/) backup of the ops VM's Semaphore state to
the append-only restic REST server of `nas-de-int-wahlberger-dev` (its
`restic_server` role), repository `ops`, via a systemd timer. The timer runs
independently of Ansible and Semaphore: a backup must not depend on the thing
it protects being reachable.

Adapted from the cloud host's role of the same name (Debian, one live
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
script is checked for both in `tests/render.d/restic.yml`. The restic env file
lives in `restic_backup_env_dir`, a different directory from the staging
directory.

## Retention: none here

The script has no `forget` or `prune` step and the role fails when
`restic_backup_forget_enabled` is true. The repository is append-only for this
host; retention and pruning run on the NAS (`restic-server-maintenance`).
Because the staging directory holds exactly the latest copy, a deleted
Semaphore project is still restorable from older snapshots until the NAS
prunes them.

## Missing database

`restic_backup_sqlite_required: true` (default, and it stays the default) makes
a missing source database fail the run and mail the owner, so an
empty-but-green backup cannot happen. The migrated database only exists from
step 4 on. The role is not applied in steps 2 to 4 (those runs use other tags), so
production `vars.yml` carries a stopgap `restic_backup_sqlite_required: false`
that is **deleted in pull request A3, before the step-5 apply** (together with
the matching `sameas false` assert in `tests/guards.d/vm_vars.yml`):

1. **Until A3**: `inventories/production/group_vars/all/vars.yml` holds, in the
   "Backups (restic_backup role)" block next to `restic_backup_forget_enabled`:

   ```yaml
   restic_backup_sqlite_required: false
   ```

   With it, the script logs `SQLite database ... is missing; skipped` and still
   takes a (database-less) snapshot, so the repository, the REST credentials and
   the NAS freshness check can be proven early if the role is applied before
   step 4 (check mode first, `--tags restic_backup`).
2. **Step 4**: the operator places the migrated database at
   `restic_backup_sqlite_databases[].src` (default
   `/opt/podman/semaphore/data/database.sqlite`).
3. **Flip back (A3)**: delete the `restic_backup_sqlite_required: false` line (the
   role default is `true`; do not set it to `false` permanently) and apply with
   `--tags restic_backup`. The rendered script changes from the skip branch to
   the hard `[ -f ... ] || exit 1` check.
4. **Prove it**: `systemctl start restic-backup.service`, then
   `journalctl -u restic-backup.service -n 30` must show no `skipped`, and
   `restic snapshots` must list a new snapshot containing
   `/var/lib/restic-backup/staging/semaphore.sqlite`.

Forgetting the flip back is not harmful while the database exists (it is
still copied), but a later disappearance of the database would no longer mail the
owner. `tests/render.d/restic.yml` renders both variants.

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

## Tests

- `tests/render-check.sh` renders the templates against production vars and
  asserts SH-AC-30 (`tests/render.d/restic.yml`).
- `roles/restic_backup/tests/behaviour.sh` runs the real rendered script in a
  disposable openSUSE container against a local throwaway repository: WAL-mode
  database copy, secrets not in the snapshot, failure on missing database.
- `tests/guards.d/restic_backup.yml` runs the real role tasks as root in a
  disposable container (`--network none`, zypper and systemctl stubbed) and
  reads back: `restic-backup.env` is `0600 root:root`, its directory, the
  staging directory and the script are `0700`, no password reaches the output,
  `restic_backup_forget_enabled` (bool or string `true`) is refused before any
  change, empty passwords are refused before any change.
