# security

SSH hardening, fail2ban, and automatic patching for openSUSE Tumbleweed. Hand-
rolled because `geerlingguy.security` (used by cloud-wahlberger-dev) doesn't
target openSUSE.

## Role variables

| Variable | Default | Description |
|----------|---------|-------------|
| `security_ssh_permit_root_login` | `"no"` | sshd `PermitRootLogin`. |
| `security_ssh_password_authentication` | `"no"` | sshd `PasswordAuthentication`. |
| `security_ssh_allow_users` | `[erikwahlberger]` | sshd `AllowUsers`. The role fails before any change if the list is empty or has an odd entry. |
| `security_ssh_max_auth_tries` | `3` | sshd `MaxAuthTries`. |
| `security_ssh_login_grace_time` | `30` | sshd `LoginGraceTime`, seconds. |
| `security_ssh_extra_directives` | `[]` | Extra `Keyword value` lines, applied first and validated like the fixed ones. |
| `security_ssh_login_notify_enabled` | `true` | Email on SSH logins from public sources. |
| `security_ssh_login_notify_ignore` | loopback + `security_fail2ban_ignoreip` | Sources that never send that email. |
| `security_fail2ban_enabled` | `true` | Install/enable fail2ban for sshd. |
| `security_fail2ban_bantime` | `3600` | Ban duration in seconds. |
| `security_fail2ban_findtime` | `600` | Window in which `maxretry` failures ban. |
| `security_fail2ban_maxretry` | `5` | Failed attempts before a ban. |
| `security_fail2ban_ignoreip` | `[10.10.0.0/16, 10.243.0.0/16]` | Never banned; `127.0.0.0/8` is always added. The host sets the full SH-FR-124 list (also the Semaphore subnet and cloud's public IPv4). |
| `security_fail2ban_banaction` | `nftables-multiport` | Ban action; never a firewalld rich-rule action (SH-FR-211). |
| `security_autoupdate_enabled` | `true` | Install the weekly `zypper-dup` service and timer. |
| `security_autoupdate_on_calendar` | `Sun *-*-* 04:00:00 Europe/Berlin` | `OnCalendar` of the timer. |
| `security_autoupdate_reboot` | `false` (production: `true`) | Request a reboot via rebootmgr after a dup that needs one. |
| `security_autoupdate_reboot_window_start` | `Sun 04:00` | rebootmgr `window-start` (systemd calendar expression). |
| `security_autoupdate_reboot_window_duration` | `1h` | rebootmgr `window-duration`. |
| `security_autoupdate_reboot_strategy` | `maint-window` | rebootmgr `strategy`. |
| `security_snapper_enabled` | `true` | Install `snapper` + `snapper-zypp-plugin` (btrfs pre/post pairs). |
| `security_sudoers_passwordless` | `[]` | Usernames granted passwordless sudo (Semaphore's unattended runs). |

## Don't lock yourself out

This is the only host with public SSH (SH-R-01). Key-based SSH must already
work before this role runs, because password auth is off and `AllowUsers`
admits only `security_ssh_allow_users`. Guards, in the order they act:

1. Empty `security_ssh_allow_users` fails the role before any change.
2. Every directive is written with `validate: sshd -t -f %s`. A file sshd
   rejects is never installed, the task fails and sshd keeps its running
   configuration (SH-FR-121, SH-AC-45, SH-E-30).
3. sshd is **reloaded**, never restarted (SH-FR-188): a restart would drop the
   connection of a Semaphore self-run on this very host.
4. `UsePAM yes` is set explicitly. OpenSSH without PAM refuses public-key
   logins for accounts whose shadow field starts with `!`, and this role locks
   every password. The reload happens (flush) before the locks.

After the first run: `sudo sshd -T | grep -E 'permitrootlogin|passwordauthentication|authenticationmethods|allowusers|usepam'`
and open a second session before closing the first.

## sshd directives

`PermitRootLogin no`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`,
`AuthenticationMethods publickey`, `AllowUsers <list>`, `MaxAuthTries 3`,
`LoginGraceTime 30`, `AllowTcpForwarding no`, `AllowAgentForwarding no`,
`X11Forwarding no`, `UsePAM yes`. New directives are inserted at the top of
`/etc/ssh/sshd_config` (sshd takes the first value, and a trailing `Match`
block cannot swallow them).

## /etc/ssh/sshd_config may not exist yet

openSUSE Tumbleweed ships the stock file as `/usr/etc/ssh/sshd_config` and has no
`/etc/ssh/sshd_config` until an admin creates one (sshd then falls back to the vendor
file). Creating a bare file would shadow it and drop `Subsystem sftp`, `AcceptEnv` and
`PrintMotd no`. So the role **copies the vendor file to `/etc/ssh/sshd_config` when
that file is missing** (never overwriting an existing one), drops the vendor's early
`Include /etc/ssh/sshd_config.d/*.conf` line from that copy, applies its directives,
and appends the `Include` **after** them, so a later drop-in cannot override the
hardening (sshd takes the first value). The role stops with a clear message if neither
file exists. Molecule asserts `sshd -T` still shows `subsystem sftp`.

## Locked passwords (SH-FR-122)

Every account whose `/etc/shadow` field does not start with `!` or `*` is locked
with `usermod -L` (the hash stays, `usermod -U` reverses it). A second run
changes nothing.

## fail2ban

`[sshd]` jail: 5 failures within 600 s ban for 3600 s. The ban action is
`nftables-multiport`, which uses its own nftables table; the public firewalld
zone gets no rich rule (SH-FR-211, SH-AC-03). No email per ban (SH-D-18).

## Login email (SH-FR-125)

`ssh-login-notify.service` follows `journalctl -u sshd.service` and mails the
owner (Resend, credentials from `notify_failure`) for every "Accepted publickey"
whose source is outside `security_ssh_login_notify_ignore`: user, source
address, key fingerprint. Chosen over a PAM hook because a broken PAM line can
lock everybody out, a broken watcher cannot. A failed send is logged to the
journal and the login is never affected (SH-E-32); there is no retry.
The mail has a text part and an HTML part. The HTML comes from
`templates/login-email-template.html.j2` (deployed to
`/etc/ssh-login-notify/email-template.html`, same look as the `reboot_notify`
mail) with `@@HOST@@`, `@@TIME@@`, `@@USER@@`, `@@ADDR@@`, `@@PORT@@`,
`@@ALG@@`, `@@FINGERPRINT@@` placeholders. The user name and address come from
the login, so every value is control-character-stripped, length-capped and
`html.escape`d, and substituted in a single pass (a user called `@@HOST@@`
stays literal); the subject is stripped of control characters. If the template
is unreadable the mail goes out as text only. Unit tests:
`tests/unit/test_ssh_login_notify.py`.
Limitation (SH-R-01): an attacker with root can stop the service, and
a pre-authentication exploit logs no login at all. The service is a Python 3
script (`files/ssh-login-notify.py`), so `shellcheck` does not apply to it; the
Molecule verify runs it against a local fake Resend endpoint.

## Weekly update: `zypper dup` (SH-FR-71..76)

`zypper-dup.timer` starts `zypper-dup.service` on **Sunday 04:00 Europe/Berlin**
(`OnCalendar=Sun *-*-* 04:00:00 Europe/Berlin`, `Persistent=true`: a run missed
while the host was off happens at the next boot). The service runs
`zypper --non-interactive dup --auto-agree-with-licenses`; exit code 102
("reboot needed") counts as success. Any other failure triggers
`OnFailure=notify-failure-immediate@%n.service` (an email via `notify_failure`).
Inspect: `systemctl list-timers zypper-dup.timer`, `journalctl -u zypper-dup.service`.

This replaces the NAS's weekly `zypper patch`. Tumbleweed is a rolling release,
so `dup` is the supported way to update it.

`common_upgrade: false` leaves the full upgrade out of the `common` role (tested by
`tests/guards.d/security_updates.yml`); with the default (`true`) `common` still
upgrades on every run.

## Reboots: rebootmgr maintenance window (PA-8)

With `security_autoupdate_reboot: true` (set in the production `group_vars`):

1. After a successful dup, `zypper-dup-request-reboot.sh` (ExecStartPost) checks
   `zypper needs-rebooting`. Only exit code 102 means a reboot is needed.
2. It first calls `reboot_notify`'s `reboot-notify.sh` (heads-up email, once per
   pending reboot: `/var/run/reboot-notify-sent` is set only when the script
   exited 0, so a failed heads-up is sent again on the next run), then
   `rebootmgrctl reboot`. That is a **request**: the script
   never calls `systemctl reboot` or `shutdown`, and always exits 0.
3. `rebootmgrd` performs the reboot only inside the maintenance window. It is
   configured in `/etc/rebootmgr/rebootmgr.conf` (strategy `maint-window`,
   `window-start=Sun 04:00`, `window-duration=1h`). rebootmgr 4 ignores the old
   `/etc/rebootmgr.conf`, so the role removes that file if present.

**Overrun:** if the dup finishes after 05:00 the request is queued and the reboot
happens in the next window (the following Sunday 04:00), never outside it. Check on
the host with `rebootmgrctl status` and `rebootmgrctl get-window` (or
`rebootmgrctl is-active`); cancel a queued reboot with `rebootmgrctl cancel`.
Molecule asserts the config file and what the running daemon reports
(`rebootmgrctl get-strategy`, `get-window`). That a queued request really waits
for the window is rebootmgr's own behaviour and is not exercised in a container; it
is checked on the fixture VM (T-16) and live (OP-W, AC-28).

## Snapshots: snapper pre/post pairs (SH-FR-25)

`snapper` and `snapper-zypp-plugin` are installed (`security_snapper_enabled`). The
plugin takes a pre and a post snapshot around every zypper transaction through the
`root` snapper config. If the root filesystem is btrfs and no config exists yet,
the role creates it (`snapper -c root create-config /`). Check:
`sudo snapper -c root list`.

**Non-btrfs root:** nothing is snapshotted (the plugin only acts on a snapper config,
and `snapper` cannot snapshot ext4/xfs); the run prints a warning. Take a Hetzner
snapshot of the server before relying on a rollback point, for example before
the first dup after provisioning.

## Check mode on a fresh host (`--check`)

The tasks that enable/start fail2ban, `ssh-login-notify`, sshd, rebootmgr and the
zypper-dup timer, and the matching handlers, tolerate the one error "Could not find
the requested service" **in check mode only** (the package or unit file was only
simulated). A real run still fails on it, and every other error still fails in
check mode.
