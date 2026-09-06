# notify_failure

Sends a failure notification email via [Resend](https://resend.com/) when a
systemd unit's `OnFailure=` hook fires — but only once that unit has failed
`notify_failure_crash_threshold` times within
`notify_failure_crash_window_seconds` (default: 5 times within 10 minutes),
not on every individual restart. This only covers services that crash on a
host that's still up and running — it can't tell you a host went dark
entirely (crashed, lost power, lost network), since nothing running on a
dead host can report its own death. That's a separate, external watcher
(planned: Uptime Kuma on `cloud-wahlberger-dev`), not this role.

## How it works

This role deploys five things:

1. `/usr/local/bin/notify-failure.sh` — a script that `curl`s Resend's REST
   API directly. No mail transport agent (postfix/msmtp) needed on any
   host — deliberately lighter than setting up real SMTP relaying
   identically across Debian and openSUSE.
2. `notify-failure@.service` — a systemd **template** unit, the default
   entry point. Any monitored unit adds `OnFailure=notify-failure@%n.service`
   to its own `[Unit]` section; `%n` expands to that unit's own name, which
   systemd passes through as the `%i` instance parameter, so one template
   handles any number of monitored services. Applies the crash-loop dedup
   below.
3. `notify-failure-immediate@.service` — the same script, but with
   `NOTIFY_CRASH_THRESHOLD` forced to `1` via a unit-level `Environment=`.
   That key is deliberately absent from `notify-failure.env` (below) —
   `EnvironmentFile=` always wins over a same-named `Environment=` on this
   systemd, confirmed empirically, so a unit-level override only works when
   the shared file doesn't also define the key. For units with **no
   `Restart=`** at all — a
   `Type=oneshot` job like `restic-backup.service`, or a native service like
   Samba's `smb`/`nmb` with no auto-restart configured — there's no
   repeating flap to deduplicate in the first place, and for a job that only
   runs once a night, the default 5-in-10-minutes window would realistically
   never even be reached (each failure would be a day apart). Use this
   variant (`OnFailure=notify-failure-immediate@%n.service`) for any unit
   like that; use the default for anything with `Restart=always` — a real
   sustained failure there retries fast enough (no `RestartSec=` set
   anywhere in this repo, so ~100ms apart) to still hit the default
   threshold almost instantly, so the dedup there is only filtering out
   one-off transient blips, not delaying real detection.
4. `/etc/notify-failure/notify-failure.env` — the Resend API key, from/to
   addresses, log-tail length, and crash-loop settings, root-only.
5. `/etc/notify-failure/email-template.html` — a static HTML email, with
   `@@UNIT@@`/`@@HOST@@`/`@@TIME@@`/`@@STREAK@@`/`@@LOG_CAPTION@@`/`@@LOGS@@`
   tokens the script fills in at send time via `jq` (not Jinja2 — nothing
   here is known until the actual failure happens).

This role only deploys the *mechanism*. It does not add `OnFailure=` to any
service itself — that's a one-line addition in the monitored service's own
role/template. Currently wired up for every container Quadlet across all
three playbooks (deduped) plus `nas-de-int-wahlberger-dev`'s
`restic-backup.service` and `smb`/`nmb`, and all three playbooks'
`disk-space-check.service` (immediate).

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

## Crash-loop dedup: one email per incident, not one per restart

`OnFailure=` fires on *every* failed start, including each cycle of a unit
that's set to `Restart=always` and keeps auto-restarting — there's no
built-in systemd knob for "only tell me after N in a row." So the counting
lives in the script itself: a per-unit counter and timestamp under
`/run/notify-failure/` (tmpfs — a fresh boot legitimately means "start
counting again", and the directory has to be created by the script at
runtime rather than by Ansible, precisely because `/run` doesn't survive a
reboot for Ansible to have pre-created it into).

Each invocation increments that unit's count if the last failure was within
`notify_failure_crash_window_seconds`, or resets it to 1 if the streak had
gone quiet longer than that. An email is sent **only** on the exact
`notify_failure_crash_threshold`-th failure of a streak — nothing for the
1st through 4th (a self-healing blip should never reach an inbox), and
nothing for the 6th, 7th, 8th... of an ongoing incident either, so a unit
stuck permanently crash-looping still only ever sends one email, not an
endless stream. A fresh incident later (after a genuine quiet period) gets
its own fresh count and its own single alert once it, too, crosses the
threshold.

## Role variables

See `defaults/main.yml`. `notify_failure_resend_api_key` is required — set
`vault_notify_failure_resend_api_key` in Ansible Vault.
`notify_failure_from_address` **must** be on a domain verified in your
Resend account, or sending silently fails.

## Testing it without waiting for a real failure

The script expects `RESEND_API_KEY`/`NOTIFY_FROM`/`NOTIFY_TO`/
`NOTIFY_LOG_LINES`/`NOTIFY_CRASH_THRESHOLD`/`NOTIFY_CRASH_WINDOW_SECONDS` as
environment variables (normally supplied by `notify-failure@.service`'s
`EnvironmentFile`) — source them first when running it by hand:

```sh
sudo -i
set -a; . /etc/notify-failure/notify-failure.env; set +a
```

`sshd.service` (or any currently-running unit) works fine as the target
even though it hasn't actually failed — the script only reads that unit's
*current* invocation's logs, it doesn't check whether it's actually in a
failed state.

To see an email immediately, without the crash-loop dedup getting in the
way, override the threshold for just this one call:

```sh
NOTIFY_CRASH_THRESHOLD=1 /usr/local/bin/notify-failure.sh sshd.service
```

To actually exercise the dedup logic end-to-end instead — confirms the
1st-through-4th calls stay silent and only the 5th sends:

```sh
for i in 1 2 3 4 5; do /usr/local/bin/notify-failure.sh sshd.service; done
```

Either way, delete the state file first if you've already run either test
recently and want a clean streak: `rm -f /run/notify-failure/sshd.service`.
