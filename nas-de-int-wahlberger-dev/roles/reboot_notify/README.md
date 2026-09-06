# reboot_notify

Emails a heads-up right before this host reboots itself for a pending
`zypper`/`rebootmgr` update — enabled by `security_autoupdate_reboot: true`
(see `roles/security/README.md`'s "Automatic reboot (rebootmgr)" section for
how that reboot is actually requested and carried out). Without this, a
patch-triggered reboot happens silently with no signal anywhere that it
happened, let alone why.

This is its own notification class, not a failure alert — a distinct role,
a distinct systemd unit, and a distinct (blue "REBOOTING", not red
"FAILED") email template. It only *reuses*
[`notify_failure`](../notify_failure/README.md)'s Resend API credentials
file (`/etc/notify-failure/notify-failure.env`) so the key doesn't need a
second copy in Vault — the same pattern `restic_backup`'s success email
already uses. It does not go through `notify_failure`'s own alerting
mechanism (`OnFailure=`, crash-loop dedup) at all.

## Why a systemd shutdown hook, not a rebootmgr hook

Same idiom as `cloud-wahlberger-dev`/`pi-de-int-wahlberger-dev`'s
`reboot_notify` role (unattended-upgrades/needrestart there, zypper/
rebootmgr here — see that role's README for the full reasoning): a trivial
always-"active" oneshot service (`ExecStart=/bin/true`,
`RemainAfterExit=true`) whose `ExecStop=` only runs when systemd actually
stops it — which `Before=shutdown.target reboot.target halt.target`
guarantees happens as part of every shutdown/reboot transaction, whatever
triggered it. `After=network-online.target` (which also affects the *stop*
order, since systemd stops units in the reverse of their start order) means
this gets stopped — and so sends its email — **before** networking goes
down, not after.

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

Forcing a real reboot just to test this is overkill. If the host currently
needs a reboot (`zypper needs-rebooting` exits 102), you can exercise the
real path directly:

```sh
sudo systemctl stop reboot-notify.service   # runs ExecStop= without rebooting
sudo systemctl start reboot-notify.service  # re-arm for the next real shutdown
```

If it doesn't, `sudo /usr/local/bin/reboot-notify.sh` on its own is a no-op
(exits silently) — that's correct, not a bug.
