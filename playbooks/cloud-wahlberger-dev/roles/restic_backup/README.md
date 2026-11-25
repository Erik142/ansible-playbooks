# restic_backup

Nightly [restic](https://restic.net/) backup of this host's `/opt/podman`
(Pocket ID, FreshRSS, Beszel's hub) to the append-only restic REST server
of `nas-de-int-wahlberger-dev` (its `restic_server` role; the host is
`restic_backup_rest_server_host`), via a systemd timer (not orchestrated through
Ansible/Semaphore itself — the timer runs independently of whether/when the
playbook is re-applied). A stopgap until a Hetzner Storage Box (and/or the
TrueNAS instance in Borås) is added as a further target — see the top-level
README.

Modeled directly on `nas-de-int-wahlberger-dev`'s role of the same name, but
simpler: this host has no separate Postgres container for anything (Pocket
ID and FreshRSS use embedded SQLite; Beszel's hub uses PocketBase's own
SQLite), so there's no `pg_dump` step and nothing needs excluding from
`restic_backup_paths` — a live filesystem copy of `/opt/podman` is fine for
embedded SQLite: unlike a separate Postgres container (which needs a
`pg_dump` step, see `nas-de-int-wahlberger-dev`'s role of the same name), a
live copy of an SQLite file is restorable as-is.

## `Environment=HOME=/root` — why it's needed

systemd services run with a minimal environment: no `$HOME`, no
`$XDG_CACHE_HOME`. restic needs one of those to locate its local metadata
cache, and fails with `unable to locate cache directory` without it — the
repository itself still gets created fine (that step doesn't need the
cache), so the failure only shows up on the very next restic command. The
service runs as root (no `User=` set), so `HOME=/root` is correct here.

## Success emails

`restic_backup_notify_on_success` (default `true`) emails a summary — the
same "Files: N new, Added to repository: X GiB, processed in HH:MM" restic
prints itself — via Resend on every successful run, not just failures
(`notify_failure` already covers those). It reuses `notify_failure`'s
Resend credentials rather than duplicating that secret into a second Vault
entry, by adding its env file as a second `EnvironmentFile=` on
`restic-backup.service` — which means `notify_failure` **must** run before
this role (already the case in `site.yml`). Set the flag to `false` to only
ever hear about this backup when it fails.

The backup's own output is captured (not just streamed to the journal) so
it can be embedded in the email, but still gets echoed afterward either way
— it's not swallowed. It's captured via `if ! OUTPUT="$(restic backup ...)"`,
deliberately not `restic backup ... | tee ...`: a pipeline's exit status is
its *last* command's (`tee`, which always succeeds), which would silently
hide a real backup failure from `set -e`.

A failure to *send* the success email (a bad API response, a `jq` bug) is
swallowed rather than propagated — the backup itself already succeeded by
that point, and letting a notification hiccup flip the whole service to
"failed" would perversely trigger `notify_failure`'s failure email over a
backup that actually worked.

## Integrity checking

Every run also does `restic check` (the repository's structure/index —
cheap, no data read) followed by `restic check --read-data-subset=10%`
(actually re-reads and re-hashes that fraction of the real data blobs,
rotating through a different slice each run). Full data-integrity coverage
completes roughly every 10 nights, without ever re-downloading the whole
repository in one go — a `restic backup` succeeding only proves the upload
worked, not that the stored data is still intact months later; this is
what actually catches that. A failed check fails the whole script (same
`set -e` propagation as a failed backup), so it raises the exact same
`notify_failure` alert. Tune the fraction with
`restic_backup_check_read_data_subset` (accepts restic's own syntax, e.g.
`"10%"` or `"1/10"`).

## Retention switch (`restic_backup_forget_enabled`) — append-only target

With `restic_backup_forget_enabled: true` (the default) the script runs
`restic forget` with the `restic_backup_keep_*` values after each backup.
With `restic_backup_forget_enabled: false` the target is append-only for
this client and the NAS applies retention: the rendered script contains no
forget/prune step at all (comments included), only the backup and the
nightly integrity check.

## Why 04:30

The NAS's rebootmgr window is 03:00-04:00, so the backup starts at 04:30
(`restic_backup_on_calendar`) to stay clear of it. A run is expected to
take at most 60 minutes and so ends before the NAS maintenance run at
06:00.

## Why a systemd timer, not a Semaphore-scheduled Ansible run

The backup itself (the backup plus, while `restic_backup_forget_enabled` is true, retention) is a
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
  `nas-de-int-wahlberger-dev`'s `vault_restic_server_cloud_htpasswd_password`
  (the Pi's playbook uses the same value under the same key while its frozen
  repository still exists; each backup client gets its own htpasswd entry —
  see `roles/restic_server/README.md` in the NAS playbook). Generate it once,
  put it in both playbooks' Vaults.

## Restoring

From this host (or any host with `restic` and the same `RESTIC_REPOSITORY`/
`RESTIC_PASSWORD`):

```sh
export $(grep -v '^#' /var/lib/restic-backup/restic-backup.env | xargs)
restic snapshots
restic restore latest --target /tmp/restore
```

Everything comes back as plain files under `/opt/podman/<service>/` — no
database dump to separately restore, unlike nas-de-int-wahlberger-dev's
Paperless-ngx/Immich. Stop the affected service's container before copying
files back into its real data directory, then start it again.
