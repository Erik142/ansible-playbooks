# restic_backup

Nightly [restic](https://restic.net/) backup of this host's `/opt/podman`
(Pocket ID, FreshRSS, Beszel's hub) to `pi-de-int-wahlberger-dev`'s
`restic_server` role, via a systemd timer (not orchestrated through
Ansible/Semaphore itself — the timer runs independently of whether/when the
playbook is re-applied). A stopgap until a Hetzner Storage Box (and/or the
TrueNAS instance in Borås) is added as a further target — see the top-level
README.

Modeled directly on `nas-de-int-wahlberger-dev`'s role of the same name, but
simpler: this host has no separate Postgres container for anything (Pocket
ID and FreshRSS use embedded SQLite; Beszel's hub uses PocketBase's own
SQLite), so there's no `pg_dump` step and nothing needs excluding from
`restic_backup_paths` — a live filesystem copy of `/opt/podman` is fine, the
same reasoning nas's role already applies to Mealie's SQLite database.

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

## Why 03:30, not nas-de-int-wahlberger-dev's 03:00

Both hosts back up to the same `restic_server` on `pi-de-int-wahlberger-dev`
— offset by half an hour so the two nightly runs don't land on it at
literally the same moment.

## Why a systemd timer, not a Semaphore-scheduled Ansible run

The backup itself (`restic backup` + `restic forget --prune`) is a
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
  `pi-de-int-wahlberger-dev`'s `vault_restic_server_cloud_htpasswd_password`
  (a *different* Vault key than nas-de-int-wahlberger-dev uses, since each
  backup client gets its own htpasswd entry — see
  `roles/restic_server/README.md` on the Pi playbook). Generate it once, put
  it in both playbooks' Vaults.

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
