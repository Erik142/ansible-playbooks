# reboot_notify

Emails a heads-up as soon as this host is known to need a reboot for a
pending `zypper`/`rebootmgr` update — enabled by
`security_autoupdate_reboot: true` (see `roles/security/README.md`'s
"Automatic reboot (rebootmgr)" section for how that reboot is actually
requested and carried out). Without this, a patch-triggered reboot happens
silently with no signal anywhere that it happened, let alone why.

This is its own notification class, not a failure alert — a distinct role
and a distinct (blue "REBOOTING", not red "FAILED") email template. It
only *reuses* [`notify_failure`](../notify_failure/README.md)'s Resend API
credentials file (`/etc/notify-failure/notify-failure.env`) so the key
doesn't need a second copy in Vault — the same pattern `restic_backup`'s
success email already uses. It does not go through `notify_failure`'s own
alerting mechanism (`OnFailure=`, crash-loop dedup) at all.

## Emails synchronously, called from security's reboot-request script

`reboot-notify.sh` (this role) is invoked directly by
`roles/security/templates/request-reboot-if-needed.sh.j2`, right when that
script decides a reboot is needed and is about to call `rebootmgrctl
reboot` — not via a separate shutdown-time systemd unit, which is how this
role worked until 2026-09.

That original design used the standard systemd run-something-on-shutdown
idiom: a trivial always-"active" oneshot service (`ExecStart=/bin/true`,
`RemainAfterExit=true`) whose `ExecStop=` only runs when systemd actually
stops it — reasoning that `Before=shutdown.target reboot.target
halt.target` guarantees inclusion in every shutdown/reboot transaction.
**Confirmed unreliable in practice**: on a real reboot, with the shutdown
transaction busy handling roughly a dozen Podman containers stopping at
the same time (their own `OnFailure=` hooks failing to enqueue with
"transaction is destructive" errors), `reboot-notify.service`'s
`ExecStop=` silently never ran at all — no error, just nothing in the
journal. `Before=` is only a soft ordering hint, not a guarantee. The same
failure was independently confirmed on `pi-de-int-wahlberger-dev`'s
equivalent unit.

Calling `reboot-notify.sh` directly from the reboot-request script instead
sidesteps the problem entirely — it's an ordinary foreground script, not
competing for a slot in a shutdown transaction — and as a bonus gives
advance notice (right when the reboot is requested) instead of a
same-instant one right as the host goes down. The caller only calls it
once per pending reboot (gated on `/var/run/reboot-notify-sent`, tmpfs, so
it resets naturally on the actual reboot), so a later weekly patch run
while the reboot is still pending doesn't send a duplicate.

## Why it doesn't fire on every reboot

The script gates on `zypper needs-rebooting` exiting `102`
(`ZYPPER_EXIT_INF_REBOOT_NEEDED`) — zypper's own built-in, no extra
package needed (unlike Debian, which has no equivalent — see the other
`reboot_notify`'s README). A manual `reboot`/`shutdown` with no pending
kernel update stays silent — the check reports "not needed," so there's
nothing accurate to say.

## Role variables

None — see `defaults/main.yml`. Reuses notify_failure's
`/etc/notify-failure/notify-failure.env` (Resend API key, from/to
addresses) instead of duplicating them.

## Manual test

If the host currently needs a reboot (`zypper needs-rebooting` exits
`102`), `sudo /usr/local/bin/reboot-notify.sh` sends the same email this
role's caller sends. If it doesn't, running it is a no-op (exits
silently) — that's correct, not a bug.
