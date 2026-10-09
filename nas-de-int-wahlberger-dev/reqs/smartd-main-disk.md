## Feature: smartd monitoring of the main data HDD (role `smartd`)
status:            ready
priority:          should
version:           1.0
quality:           not scored

### Problem Statement

Only the backup disk was planned to be watched by smartd, and only after the cut-over (`backup_disk_enabled`). The main data HDD behind `/mnt/data` holds the primary copy of everything, yet nothing warns of failing SMART attributes. The generic `smartd` role watches a list of disks from day one, independent of the backup-disk gating. It also owns the shared mail hook and `smartd.service` that `backup_disk` reuses (see [backup-disk-init.md](backup-disk-init.md), BD-FR-37 to BD-FR-42).

### Functional Requirements

- SM-FR-1 [Must]: For every `smartd_devices` entry the playbook shall write one line to `smartd_conf` that starts with the entry's `/dev/disk/by-id/` path and contains `-a` and `-s <schedule>`, where the schedule is the entry's `schedule` or else `smartd_default_schedule` (default `(S/../../7/01|L/../01/./10)`).
- SM-FR-2 [Must]: The default `smartd_devices` shall contain exactly the main data HDD `/dev/disk/by-id/ata-TOSHIBA_MG04ACA600EY_57I9K068FTTB`.
- SM-FR-3 [Must]: When smartd logs a warning for a listed disk, an email shall reach `notify_failure_to_address` within 5 min, sent with the `notify_failure` Resend credentials through the hook at `smartd_hook_path`.
- SM-FR-4 [Must]: The SM-FR-3 email shall contain the device path and smartd's message text.
- SM-FR-5 [Must]: `smartd.service` shall be enabled and active, and shall be restarted only when a device line changed.
- SM-FR-6 [Should]: Every device line and `DEVICESCAN` line in `smartd_conf` before a run shall still be present after it, and each managed line shall precede `DEVICESCAN`.
- SM-FR-7 [Must]: The `smartd` role shall run whether or not `backup_disk_enabled` is true, after `notify_failure` and before `backup_disk`.
- SM-FR-8 [Should]: Where an entry sets `standby: true`, its line shall contain `-n standby`.

### Acceptance Scenarios

Scenario SM-AC-01 [S]: The default line is rendered (SM-FR-1, SM-FR-2, SM-FR-8)
- Given the role defaults
- When `tests/render-check.sh` renders `smartd-line.j2` for the default device
- Then the line is `/dev/disk/by-id/ata-TOSHIBA_MG04ACA600EY_57I9K068FTTB -a -s (S/../../7/01|L/../01/./10) -m root -M exec /usr/local/bin/smartd-notify.sh`
- And with `standby: true` it contains `-n standby`

Scenario SM-AC-02 [S]: The hook carries device and message (SM-FR-3, SM-FR-4)
- Given the rendered `smartd-notify.sh`
- When the operator greps it
- Then it reads `/etc/notify-failure/notify-failure.env`, uses `SMARTD_DEVICE` and `SMARTD_FULLMESSAGE`, and posts to `api.resend.com/emails`

Scenario SM-AC-03 [S]: Ordering and gating (SM-FR-7)
- Given `site.yml` with `backup_disk_enabled: false`
- When `tests/static-checks.sh` runs AC-05
- Then `smartd` has tasks, and comes after `notify_failure` and before `backup_disk`

Scenario SM-AC-04 [H]: Idempotent run on the NAS (SM-FR-1, SM-FR-5, SM-FR-6)
- Given the NAS with an existing `DEVICESCAN` line
- When the operator applies `--tags smartd` twice
- Then the first run adds the line above `DEVICESCAN` and restarts smartd, the second reports 0 changed
- And `systemctl is-active smartd` prints `active`

### Traceability

| Requirement | Verification | Scenario |
|---|---|---|
| SM-FR-1, SM-FR-2, SM-FR-8 | render check [S] | SM-AC-01 |
| SM-FR-3, SM-FR-4 | render check [S], smoke [H] | SM-AC-02, BD-AC-82 |
| SM-FR-5, SM-FR-6 | smoke [H] | SM-AC-04 |
| SM-FR-7 | static check [S] | SM-AC-03 |

### Out of Scope

Monitoring the root SSD and the NVMe (one list entry each; see `roles/smartd/README.md`).

### Open Questions

None.
