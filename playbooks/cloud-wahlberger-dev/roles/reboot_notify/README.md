# reboot_notify

Emails a heads-up as soon as this host is known to need a reboot for a
pending `unattended-upgrades` update — enabled by
`security_autoupdate_reboot: "true"` (see `cloud-wahlberger-dev`'s
top-level `group_vars`). Without this, a security-patch reboot happens
silently at `security_autoupdate_reboot_time` (default 03:00) with no
signal anywhere that it happened, let alone why.

This is its own notification class, not a failure alert — a distinct role
and a distinct (blue "REBOOTING", not red "FAILED") email template. It
only *reuses* [`notify_failure`](../notify_failure/README.md)'s Resend API
credentials file (`/etc/notify-failure/notify-failure.env`) so the key
doesn't need a second copy in Vault — the same pattern `restic_backup`'s
success email already uses. It does not go through `notify_failure`'s own
alerting mechanism (`OnFailure=`, crash-loop dedup) at all.

`nas-de-int-wahlberger-dev` has its own copy of this role, same idiom and
name, different internals (zypper/rebootmgr instead of
unattended-upgrades/needrestart) — see its README for that variant.

## Debian doesn't have Ubuntu's reboot-required flag — needrestart fills the gap

`unattended-upgrades`' own `Automatic-Reboot` feature, and this role's
email gate, both key off `/var/run/reboot-required` existing. On Ubuntu
that file is maintained by `update-notifier-common`'s package hooks. That
package **doesn't exist on Debian at all** (confirmed: not in the apt
cache on this host) — meaning without a fix, `security_autoupdate_reboot:
"true"` would be a silent no-op, never actually rebooting anything.

This role installs `needrestart` instead (Debian's own suggested
companion for `unattended-upgrades`, per its README) and adds an apt
`DPkg::Post-Invoke` hook (`/etc/apt/apt.conf.d/99-reboot-required` — a
separate file from needrestart's own `99needrestart`, which this role must
not overwrite) that runs after every apt/dpkg transaction, including
`unattended-upgrades`' own nightly one. It parses `needrestart -b`'s
machine-readable output: `NEEDRESTART-KSTA: 3` means the installed kernel
genuinely differs from the running one (1 = matches, 2 = ABI-only bump,
neither needs a reboot), and only then touches
`/var/run/reboot-required` — with `/var/run/reboot-required.pkgs` recording
which kernel versions triggered it, for the email's package panel.

A manual `reboot`/`shutdown` with no pending kernel update stays silent —
the file won't exist, so there's nothing accurate to say.

## Emails synchronously at detection time, not via a shutdown hook

`check-reboot-required.sh` sends the email itself, the moment it first
touches `/var/run/reboot-required` — not a separate shutdown-time systemd
unit, which is how this role worked until 2026-09.

That original design used the standard systemd run-something-on-shutdown
idiom: a trivial always-"active" oneshot service (`ExecStart=/bin/true`,
`RemainAfterExit=true`) whose `ExecStop=` only runs when systemd actually
stops it — reasoning that `Before=shutdown.target reboot.target
halt.target` guarantees inclusion in every shutdown/reboot transaction.
**Confirmed unreliable in practice**: on a real reboot, with the shutdown
transaction busy handling several other services stopping at the same
time (their own `OnFailure=` hooks failing to enqueue with "transaction is
destructive" errors), `reboot-notify.service`'s `ExecStop=` silently never
ran at all — no error, just nothing in the journal. `Before=` is only a
soft ordering hint, not a guarantee. The same failure was independently
confirmed on `nas-de-int-wahlberger-dev`'s equivalent unit.

Emailing from `check-reboot-required.sh` instead sidesteps the problem
entirely — it's an ordinary foreground apt hook script, not competing for
a slot in a shutdown transaction — and as a bonus gives advance notice
(as soon as a reboot is known to be needed) instead of a same-instant one
right as the host goes down. It only emails the first time a reboot is
detected since the last actual reboot (`/var/run` is tmpfs, so this resets
naturally), so a later apt/dpkg run while the reboot is still pending
doesn't send a duplicate.

## Role variables

None — see `defaults/main.yml`. Reuses notify_failure's
`/etc/notify-failure/notify-failure.env` (Resend API key, from/to
addresses) instead of duplicating them.

## Manual test

`sudo needrestart -b -r a` shows the live `NEEDRESTART-KSTA` value, and
`sudo /usr/local/bin/check-reboot-required.sh` runs the same check (and,
the first time, sends the same email) this role's apt hook runs after
every upgrade. Remove `/var/run/reboot-required` first
(`sudo rm -f /var/run/reboot-required /var/run/reboot-required.pkgs`) to
re-arm the "first detection" email gate for a repeat test.
