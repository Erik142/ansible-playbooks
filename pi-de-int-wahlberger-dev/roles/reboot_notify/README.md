# reboot_notify

Emails a heads-up right before this host reboots itself for a pending
`unattended-upgrades` update — enabled by `security_autoupdate_reboot:
"true"` (see `cloud-wahlberger-dev`'s top-level `group_vars`). Without this,
a security-patch reboot happens silently at `security_autoupdate_reboot_time`
(default 03:00) with no signal anywhere that it happened, let alone why.

This is its own notification class, not a failure alert — a distinct role,
a distinct systemd unit, and a distinct (blue "REBOOTING", not red
"FAILED") email template. It only *reuses*
[`notify_failure`](../notify_failure/README.md)'s Resend API credentials
file (`/etc/notify-failure/notify-failure.env`) so the key doesn't need a
second copy in Vault — the same pattern `restic_backup`'s success email
already uses. It does not go through `notify_failure`'s own alerting
mechanism (`OnFailure=`, crash-loop dedup) at all.

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

## Why a systemd shutdown hook, not an unattended-upgrades hook

`unattended-upgrades` has no pre-reboot hook of its own — by the time
`Unattended-Upgrade::Mail` (if configured) would report anything, it's
reporting on packages installed, not specifically "about to reboot," and it
needs a local MTA this stack doesn't have (Resend is HTTP API, not SMTP).
Instead, `reboot-notify.service` uses the standard systemd idiom for
run-something-on-shutdown: a trivial always-"active" oneshot service
(`ExecStart=/bin/true`, `RemainAfterExit=true`) whose `ExecStop=` only runs
when systemd actually stops it — which `Before=shutdown.target
reboot.target halt.target` guarantees happens as part of every shutdown/
reboot transaction, whatever triggered it.

`After=network-online.target` (which also affects the *stop* order, since
systemd stops units in the reverse of their start order) means this gets
stopped — and so sends its email — **before** networking goes down, not
after.

## Role variables

None — see `defaults/main.yml`. Reuses notify_failure's
`/etc/notify-failure/notify-failure.env` (Resend API key, from/to
addresses) instead of duplicating them.

## Manual test

Forcing a real reboot just to test this is overkill. Instead:

```sh
sudo touch /var/run/reboot-required
sudo systemctl stop reboot-notify.service   # runs ExecStop= without rebooting
sudo rm -f /var/run/reboot-required /var/run/reboot-required.pkgs
```

Restart the (still-enabled) service afterwards so it's ready for a real
shutdown: `sudo systemctl start reboot-notify.service`. To exercise the
whole detection path instead of faking the flag file directly:
`sudo needrestart -b -r a` shows the live `NEEDRESTART-KSTA` value, and
`sudo /usr/local/bin/check-reboot-required.sh` runs the same check this
role's apt hook runs after every upgrade.
