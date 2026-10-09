# restic_backup_decommission

Idempotently removes the old NAS to Pi restic backup job once the new backup
chain has taken over (BD-FR-79 to BD-FR-82, cut-over step 5 of BD-BR-14).

## Purpose

After the first btrbk run has exited 0, the old `restic-backup` timer and
service on the NAS are no longer wanted. This role stops and disables
`restic-backup.timer` and `restic-backup.service`, removes their unit files,
`/usr/local/bin/restic-backup.sh`, `/etc/restic-backup` and
`/var/lib/restic-backup`, then reloads systemd. When none of these exist,
every task reports `ok`/`skipped` and the run shows `changed=0`.

`roles/restic_backup` is deleted from this repository; this role is what
removes its leftovers from the live host.

## Role variables

Only paths and unit names, all with defaults in `defaults/main.yml` and
declared in `meta/argument_specs.yml`. There is no enable flag in the role:
`site.yml` applies `restic_backup_decommission_enabled` (default `false`,
set to `true` at runbook step 5) with a `when:`. Do not enable it before the
first btrbk run has exited 0.

## What it does not do

- It never contacts `pi.de.int.wahlberger.dev` and never touches the
  repositories on the Pi (they stay as frozen fallbacks, BD-BR-13).
- It does not touch cloud's own `restic_backup` role or any backup data on
  the NAS.
- It does not uninstall the `restic` package.
- It is not wired into `site.yml` by itself (done in PLAN-backup.md T-19).
