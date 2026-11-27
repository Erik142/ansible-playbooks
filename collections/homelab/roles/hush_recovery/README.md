# hush_recovery

Deploys `/etc/systemd/system/<unit>.d/hush.conf` for each long-running unit in
`hush_recovery_units`. The drop-in adds `ExecStartPost=-hush-systemd-event ok %n`,
so Hush receives a recovery ("ok") event each time the unit starts. The problem
events stay with `OnFailure=notify-failure@`.

- Same hook script and `/etc/hush/hook.env` as `notify_failure`, so both events go
  to the same Hush source.
- `-` prefix: a failed post does not fail the unit.
- Runs last in `site.yml`, after every unit exists. A changed drop-in restarts that unit.
