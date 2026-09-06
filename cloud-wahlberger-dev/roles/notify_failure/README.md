# notify_failure

Sends a failure notification email via [Resend](https://resend.com/) when a
systemd unit's `OnFailure=` hook fires. This only covers services that
crash on a host that's still up and running — it can't tell you a host went
dark entirely (crashed, lost power, lost network), since nothing running on
a dead host can report its own death. That's a separate, external watcher
(planned: Uptime Kuma on `cloud-wahlberger-dev`), not this role.

## How it works

This role deploys three things:

1. `/usr/local/bin/notify-failure.sh` — a script that `curl`s Resend's REST
   API directly. No mail transport agent (postfix/msmtp) needed on any
   host — deliberately lighter than setting up real SMTP relaying
   identically across Debian and openSUSE.
2. `notify-failure@.service` — a systemd **template** unit. Any monitored
   unit adds `OnFailure=notify-failure@%n.service` to its own `[Unit]`
   section; `%n` expands to that unit's own name, which systemd passes
   through as the `%i` instance parameter, so one template handles any
   number of monitored services.
3. `/etc/notify-failure/notify-failure.env` — the Resend API key and
   from/to addresses, root-only.

This role only deploys the *mechanism*. It does not add `OnFailure=` to any
service itself — that's a one-line addition in the monitored service's own
role/template. Currently wired up for
`nas-de-int-wahlberger-dev`'s `restic-backup.service` only; add it to
another unit by adding `OnFailure=notify-failure@%n.service` to that unit's
`[Unit]` section.

## Role variables

See `defaults/main.yml`. `notify_failure_resend_api_key` is required — set
`vault_notify_failure_resend_api_key` in Ansible Vault.
`notify_failure_from_address` **must** be on a domain verified in your
Resend account, or sending silently fails.

## Testing it without waiting for a real failure

```sh
sudo /usr/local/bin/notify-failure.sh test-unit
```

This sends a real email immediately — confirms the API key, from-address,
and network path all work, independent of whether any monitored service has
actually failed.
