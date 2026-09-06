# notify_failure

Sends a failure notification email via [Resend](https://resend.com/) when a
systemd unit's `OnFailure=` hook fires. This only covers services that
crash on a host that's still up and running — it can't tell you a host went
dark entirely (crashed, lost power, lost network), since nothing running on
a dead host can report its own death. That's a separate, external watcher
(planned: Uptime Kuma on `cloud-wahlberger-dev`), not this role.

## How it works

This role deploys four things:

1. `/usr/local/bin/notify-failure.sh` — a script that `curl`s Resend's REST
   API directly. No mail transport agent (postfix/msmtp) needed on any
   host — deliberately lighter than setting up real SMTP relaying
   identically across Debian and openSUSE.
2. `notify-failure@.service` — a systemd **template** unit. Any monitored
   unit adds `OnFailure=notify-failure@%n.service` to its own `[Unit]`
   section; `%n` expands to that unit's own name, which systemd passes
   through as the `%i` instance parameter, so one template handles any
   number of monitored services.
3. `/etc/notify-failure/notify-failure.env` — the Resend API key, from/to
   addresses, and the log-tail length, root-only.
4. `/etc/notify-failure/email-template.html` — a static HTML email, with
   `@@UNIT@@`/`@@HOST@@`/`@@TIME@@`/`@@LOG_CAPTION@@`/`@@LOGS@@` tokens the
   script fills in at send time via `jq` (not Jinja2 — nothing here is known
   until the actual failure happens).

This role only deploys the *mechanism*. It does not add `OnFailure=` to any
service itself — that's a one-line addition in the monitored service's own
role/template. Currently wired up for
`nas-de-int-wahlberger-dev`'s `restic-backup.service` only; add it to
another unit by adding `OnFailure=notify-failure@%n.service` to that unit's
`[Unit]` section.

## What the email includes

The subject, heading, and detail panel all name the failed unit, the host,
and the time. Below that, the actual `journalctl` output from that specific
failed run — not the unit's whole history — using systemd's per-invocation
ID (`systemctl show -p InvocationID`) rather than a plain time-window query,
so a service that's failed many times over its life only ever shows the run
that just failed. Lines that look like errors (`error`/`fail`/`fatal`,
case-insensitive) get a red highlight — a plain heuristic, not a parser, so
it can occasionally miss or over-highlight a line; that's fine for a
skim-and-click-through email. `notify_failure_log_lines` (default 50)
caps how much gets embedded.

The HTML is escaped and highlighted *before* being substituted into the
template — not after, which would mangle the highlight `<span>` tags the
escape pass would otherwise treat as literal text — see the comment in
`notify-failure.sh.j2`.

## Role variables

See `defaults/main.yml`. `notify_failure_resend_api_key` is required — set
`vault_notify_failure_resend_api_key` in Ansible Vault.
`notify_failure_from_address` **must** be on a domain verified in your
Resend account, or sending silently fails.

## Testing it without waiting for a real failure

The script expects `RESEND_API_KEY`/`NOTIFY_FROM`/`NOTIFY_TO`/
`NOTIFY_LOG_LINES` as environment variables (normally supplied by
`notify-failure@.service`'s `EnvironmentFile`) — source them first when
running it by hand:

```sh
sudo -i
set -a; . /etc/notify-failure/notify-failure.env; set +a
/usr/local/bin/notify-failure.sh sshd.service
```

`sshd.service` (or any currently-running unit) works fine here even though
it hasn't actually failed — the script only reads that unit's *current*
invocation's logs, it doesn't check whether it's actually in a failed
state. Confirms the API key, from-address, template substitution, and
network path all work, independent of a real failure.
