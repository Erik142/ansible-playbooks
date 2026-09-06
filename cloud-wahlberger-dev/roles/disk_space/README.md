# disk_space

Periodic disk usage check via a systemd timer, emailing through the
[`notify_failure`](../notify_failure/README.md) role when a monitored
mountpoint crosses `disk_space_threshold_percent`. Nothing else in this
stack watches disk usage — a full disk otherwise fails backups and
containers silently, with no path to your inbox.

## Why "immediate", and why it doesn't spam

`disk-space-check.service` (`Type=oneshot`, no `Restart=`) uses
`OnFailure=notify-failure-immediate@%n.service` — see
`roles/notify_failure/README.md`'s immediate-vs-deduped rule. Normally that
means *every* failing run emails. That would be unusable here: the timer
runs every `disk_space_check_interval` (default 15 min), and a full disk
doesn't clear itself between checks.

So `disk-space-check.sh` does its own, simpler dedup: it's
**edge-triggered**, not level-triggered. It tracks per-path state under
`/run/disk-space-check` (tmpfs — a reboot means "start fresh") and only
exits non-zero the *first* time a path crosses the threshold. As long as
that path stays over threshold, subsequent runs see the state is already
`critical` and exit 0 — no repeat email. Once usage drops back below
threshold, state resets to `ok`, so a future crossing alerts again. This
also means every alert genuinely is a distinct occurrence, matching the
immediate variant's own assumption — no need for notify_failure's
time-window dedup on top.

## Role variables

See `defaults/main.yml`. `disk_space_paths` defaults to `["/"]` only —
override it per host for any additional mounted disks (see this repo's
other playbooks for examples: the NAS's `/mnt/data` + `/mnt/containers`,
the Pi's `/mnt/data`).

## Manual test

```sh
sudo /usr/local/bin/disk-space-check.sh
```

Prints each monitored path's usage and OK/critical/skip verdict, and exits
non-zero only on a fresh crossing. To force a test email without waiting for
a real crossing, set `disk_space_threshold_percent` to `0`, re-run Ansible,
run the script once (it'll alert), then set the threshold back and re-run
again.

To re-arm an already-alerted path without waiting for it to drop back below
threshold first, delete its state file — e.g. for `/`:
`sudo rm -f /run/disk-space-check/_` (the `/` → `_` mapping is the script's
own `tr '/' '_'`).
