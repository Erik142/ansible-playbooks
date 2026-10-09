# btrbk

Installs [btrbk](https://digint.ch/btrbk/) from a pinned, fingerprint-checked
OBS repository, writes `/etc/btrbk/btrbk.conf` and runs it daily from
`btrbk.timer`: one read-only snapshot of every `btrbk_sources` entry, sent
(incrementally) to `<btrbk_target_dir>/<name>/` on the backup disk.

## What this role does

1. Fetches the repository signing key into a private directory and compares
   its primary fingerprint with `btrbk_zypper_repo_gpg_fingerprint`. A
   mismatch, or a key file holding more than one primary key, fails the role with a message naming that variable, before the key
   is imported or the repository is added.
2. Imports the verified key (`rpm_key`, which re-checks the fingerprint).
3. Adds the repository `filesystems` with `gpgcheck=1`, `repo_gpgcheck=1` and
   priority `btrbk_zypper_repo_priority` (150). Priority 150 keeps every
   package that also exists in OSS on OSS.
4. Installs `btrbk`. It is the only package taken from this repository: the role
   never runs `zypper dup` or passes `--allow-vendor-change` for it.

5. Before any change it reads the live mount table and fails, naming the path,
   when `btrbk_target_dir` or a source path is not mounted (or, for a
   `storage_mounts` / `backup_disk_mounts` path, not from that UUID/subvolume).
6. Creates `<source>/.btrbk` (0700 root:root, inside the mounted source) and
   `<btrbk_target_dir>/<name>/` (0700): btrbk creates neither and aborts with
   exit 10 without them.
7. Renders the config and `btrbk.service` / `btrbk.timer` (01:30, `Persistent=true`).
   The service `Wants=`/`After=` `db-dump.service` (a failed dump does not stop
   btrbk), has `RequiresMountsFor=` the target and every source, and
   `OnFailure=notify-failure-immediate@%n.service`. Exit 10 fails the unit.
   `lockfile /run/btrbk.lock` prevents a second concurrent run.
8. Installs `/usr/local/bin/btrbk-key-refresh.py` with `btrbk-key-refresh.service`
   and a weekly `btrbk-key-refresh.timer` (see "Signing key renewal").

## Retention (independent of snapper, BD-BR-15)

| Side | Variables | Default | Effect |
|---|---|---|---|
| btrbk source (`<source>/.btrbk`) | `btrbk_snapshot_preserve_min` / `btrbk_snapshot_preserve` | `2d` / `no` | keep 2 days, then only the newest one with a received copy |
| btrbk target (backup disk) | `btrbk_target_preserve_min` / `btrbk_target_preserve` | `no` / `14d 8w 12m 3y` | 14 daily, 8 weekly, 12 monthly, 3 yearly |
| snapper (`.snapshots`, separate role) | snapper configs | unchanged | never read or written here |

With `target_preserve_min no`, a second run on the same day creates a source
snapshot but sends nothing (one received copy per day). For incremental tests
use `--override target_preserve_min=1h` or different days.

## Restore

Restoring one file (DOC-O1) or a whole source subvolume with btrfs
send/receive (DOC-O2) is described in the NAS restore docs; the received
snapshots are `/mnt/backup/btrbk/<name>/<name>.<timestamp>`.

## Role variables

See `defaults/main.yml`; every variable is declared in
`meta/argument_specs.yml`.

## What this role does NOT do

- It does not touch `snapper` or its configs; the two are independent.
- It does not disable GPG checking for any repository, ever.
- It does not exclude `restic_server_data_dir`: the repositories are part of the `data` snapshot (BD-FR-161).
- It does not replace a human for a key *rotation* (new fingerprint): see "Signing key renewal".
- It does not run the database dumps (`db_dump`) or take snapper snapshots.
- It does not format or mount the backup disk (`backup_disk` and `storage`).

## Fallback if the repository is unreachable (BD-D-03)

If OBS is down or the key cannot be verified, do not weaken the checks. Install
the pinned upstream btrbk Perl script from a release tag of
<https://github.com/digint/btrbk>, verify its signature against the upstream
maintainer key, and place it at `/usr/bin/btrbk`. Record the version here when
this is ever used.

## Signing key renewal (DOC-O11, BD-FR-162 to BD-FR-168)

The `filesystems` key expires on 2027-05-07 (BD-A-17). After that, `zypper
refresh` of the repository fails, and so would the weekly unattended `zypper
patch`. `btrbk-key-refresh.timer` (`btrbk_key_refresh_on_calendar`, default
`weekly`) therefore runs `btrbk-key-refresh.service`, which:

1. fetches the key over HTTPS from `btrbk_zypper_repo_key_url`;
2. requires exactly one primary key whose fingerprint equals
   `btrbk_zypper_repo_gpg_fingerprint`. Anything else fails the unit (exit 2)
   and **imports nothing**: it is a possible rotation or tampering;
3. runs `rpm --import` (this picks up an OBS-extended expiry, same key) and
   `zypper refresh <alias>`, never with `--gpg-auto-import-keys`;
4. fails (exit 1) when the fetched key expires in fewer than
   `btrbk_key_warn_days` (default 60) days, after having tried 3.

The unit has `OnFailure=notify-failure-immediate@%n.service`, so every failure
emails you; a silent run means the key is valid and renewed. Exit codes: 1
renewal problem or key near expiry, 2 key mismatch, 3 fetch failed. Read the
reason with `journalctl -u btrbk-key-refresh.service`.

**Caveat.** OBS normally re-extends project keys before they expire, under the
same fingerprint, but that is not guaranteed, and it is not verifiable before
2027-05-07 that `rpm --import` replaces the installed key with the extended
one. If it does not, the alert keeps firing until you do it by hand. The role's
install step only imports the key when it is absent; the timer does the
refresh.

**When it alerts**

- Same fingerprint, key near expiry or refresh failing: remove the old key
  (`sudo rpm -e gpg-pubkey-<id>`; list with `rpm -qa gpg-pubkey`), run
  `site.yml --tags btrbk` and `sudo systemctl start btrbk-key-refresh.service`.
- New fingerprint (exit 2): a true rotation always needs a human. Verify the
  new fingerprint out of band (`osc signkey filesystems | gpg --show-keys
  --with-fingerprint`), then set `btrbk_zypper_repo_gpg_fingerprint` and run
  `site.yml --tags btrbk`. If you cannot verify it, treat it as tampering.

## Testing

`tests/syntax-check-role.sh btrbk`. A negative test points
`btrbk_zypper_repo_key_url` at a `file://` stub key with another fingerprint and
expects the assert to fail before any repository exists.
