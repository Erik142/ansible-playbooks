# common

Baseline OS configuration for openSUSE Tumbleweed hosts: refreshes zypper
repositories, optionally runs a full update, installs a small baseline package
set, and sets the system timezone.

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
