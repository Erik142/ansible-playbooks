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

Unlike Debian's `unattended-upgrades`, `zypper patch` does **not** auto-reboot
even after a kernel update — check `zypper ps -s` periodically and reboot on
your own schedule. Inspect the timer with `systemctl status zypper-autopatch.timer`
and past runs with `journalctl -u zypper-autopatch.service`.
