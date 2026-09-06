# common

Baseline OS configuration for openSUSE Tumbleweed hosts: refreshes zypper
repositories, optionally runs a full update, installs a small baseline package
set, sets the system timezone, and sets the actual OS hostname to
`inventory_hostname` (this host's real FQDN) — not something initial
provisioning necessarily gets right on its own; `/etc/hosts` gets a matching
static fallback entry too, so `sudo` never prints "unable to resolve host"
if DNS is briefly unavailable.

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
