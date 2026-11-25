# common

Baseline OS configuration for openSUSE Tumbleweed hosts: refreshes zypper
repositories, optionally runs a full update, installs a small baseline package
set, sets the system timezone, and sets the actual OS hostname to
`inventory_hostname` (this host's real FQDN) — not something initial
provisioning necessarily gets right on its own; `/etc/hosts` gets a matching
static fallback entry too, so `sudo` never prints "unable to resolve host"
if DNS is briefly unavailable.

Also switches the systemd journal from volatile (`/run/log/journal`, wiped
on every reboot) to persistent storage, by creating `/var/log/journal` —
journald auto-detects it, no config file needed. Without this, a reboot
loses every log from before it, including whatever a shutdown-time unit
like `reboot_notify` printed about its own success or failure — exactly
the gap that made a real missed-notification incident undiagnosable.

## Role variables

| Variable | Default | Description |
|----------|---------|-------------|
| `common_packages` | `[ca-certificates, curl, gpg2, htop, vim]` | Packages installed on every host. |
| `common_timezone` | `Europe/Berlin` | IANA timezone name. |
| `common_upgrade` | `true` | Run a full `zypper update` (Tumbleweed is rolling-release). |

## Example

```yaml
- hosts: nas
  become: true
  roles:
    - role: common
      vars:
        common_timezone: Europe/Stockholm
```
