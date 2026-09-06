# security

SSH hardening, fail2ban, and automatic patching for openSUSE Tumbleweed. Hand-
rolled because `geerlingguy.security` (used by cloud-wahlberger-dev) doesn't
target openSUSE.

## Role variables

| Variable | Default | Description |
|----------|---------|-------------|
| `security_ssh_permit_root_login` | `"no"` | sshd_config `PermitRootLogin`. |
| `security_ssh_password_authentication` | `"no"` | sshd_config `PasswordAuthentication`. |
| `security_fail2ban_enabled` | `true` | Install/enable fail2ban for sshd. |
| `security_fail2ban_bantime` | `3600` | Ban duration in seconds. |
| `security_fail2ban_maxretry` | `5` | Failed attempts before a ban. |
| `security_autoupdate_enabled` | `true` | Schedule weekly `zypper patch`. |
| `security_autoupdate_on_calendar` | `Sun *-*-* 03:00:00` | systemd `OnCalendar` for the patch timer. |
| `security_autoupdate_reboot` | `false` | Reboot automatically (via rebootmgr) when zypper says one is needed. Same variable name as cloud/pi's geerlingguy.security equivalent, different mechanism. |
| `security_autoupdate_reboot_window_start` | `"03:00"` | rebootmgr's maintenance window start. |
| `security_autoupdate_reboot_window_duration` | `"1h"` | rebootmgr's maintenance window length. |
| `security_autoupdate_reboot_strategy` | `"best-effort"` | rebootmgr strategy — see below. |
| `security_sudoers_passwordless` | `[]` | Usernames granted passwordless sudo (needed for Semaphore UI's unattended runs — see `pi-de-int-wahlberger-dev`). |

## Don't lock yourself out

Key-based SSH must already work before this role runs — password auth is
turned off. Verify after the first run: `ssh erikwahlberger@nas.de.int.wahlberger.dev`
still works, and on the host `sudo sshd -T | grep -E 'permitrootlogin|passwordauthentication'` → `no`.

## /etc/ssh/sshd_config may not exist yet

Some openSUSE images ship an empty `/etc/ssh/sshd_config.d/` but no base
`/etc/ssh/sshd_config` — sshd runs entirely on compiled-in defaults until one
exists. The role creates it if missing (`create: true`), then appends an
`Include /etc/ssh/sshd_config.d/*.conf` line **after** its own hardening
directives — OpenSSH uses the first value it encounters per keyword, so any
future drop-in dropped into that directory can never re-enable root login or
password auth out from under this role.

## Automatic patching

`zypper-autopatch.service`/`.timer` runs `zypper patch` weekly. Inspect the
timer with `systemctl status zypper-autopatch.timer` and past runs with
`journalctl -u zypper-autopatch.service`.

## Automatic reboot (rebootmgr)

Unlike Debian's `unattended-upgrades`, `zypper patch` never reboots on its
own — this role wires up [rebootmgr](https://github.com/SUSE/rebootmgr)
(SUSE's own purpose-built tool for this, unlike Debian which has nothing
equivalent — see `roles/reboot_notify/README.md`) to do it, when
`security_autoupdate_reboot: true`:

1. `zypper-autopatch.service` gets an `ExecStartPost=` running
   `request-reboot-if-needed.sh` after every successful patch run.
2. That script checks `zypper needs-rebooting` (exit code 102 = a reboot is
   genuinely suggested — kernel, glibc, etc.) and, only then, calls
   `rebootmgrctl reboot` to *request* one.
3. `rebootmgrd` (its own long-running service, configured via
   `/etc/rebootmgr.conf`) decides *when* to actually carry it out, per
   `security_autoupdate_reboot_strategy`. The default, `best-effort`,
   reboots at the first reasonable opportunity once requested — it doesn't
   re-gate on the configured window on top, since the weekly patch timer
   already only requests a reboot once, right after Sunday 03:00 patching.
   Switch to `maint-window` if you want reboots strictly confined to
   `security_autoupdate_reboot_window_start`/`_window_duration` instead.

Emailing a heads-up before this actually happens is a separate role, not
this one — see `roles/reboot_notify/README.md`.

Inspect on the host: `sudo rebootmgrctl status`, `zypper needs-rebooting`.
