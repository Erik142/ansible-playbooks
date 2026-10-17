# netcup-ci-wahlberger-dev

Ansible playbook for the netcup VPS (openSUSE Tumbleweed, KIWI image from
`ops-de-wahlberger-dev/netcup-image/`) that runs a Forgejo Actions runner for the
Forgejo instance on the NAS. Layout and conventions follow `ops-de-wahlberger-dev`;
roles are copied, not shared.

## Status

Scaffold only. Nothing has been applied to the host. Open items:

| Item | Needed from owner |
|---|---|
| Public IP, interface name, static IPv4/prefix, gateway, DNS | yes |
| Live NM profile (`/etc/NetworkManager/system-connections/*.nmconnection`) | yes, to diff the template |
| Hostname (proposed `ci.de.wahlberger.dev`) | confirm |
| 1Password item name (proposed `Ansible Vault - netcup-ci-wahlberger-dev`) | confirm, then create |
| Runner registration token | when the runner role is applied |
| ZeroTier member authorization in Central; `vm_zt_ip`, `vm_zt_iface` | manual |
| ZeroTier flow rules (`docs/zerotier-flow-rules.md`) | confirm before entering |
| Confirm `git.de.int.wahlberger.dev` resolves to the NAS over ZeroTier; NAS certificate chain | verify on host |
| Enabling Actions on the NAS (`nas-de-int-wahlberger-dev`) | separate change, not applied |

## Run

```sh
cd netcup-ci-wahlberger-dev
ansible-playbook site.yml --check --diff -e ansible_host=<public-ip-or-zt-ip>
ansible-playbook site.yml -e ansible_host=<public-ip-or-zt-ip>
```

Without `ansible_host` the run connects to the public name, which does not
resolve yet. Pass the address explicitly.

## Roles

`common`, `netcup_network`, `notify_failure`, `disk_space`, `ssh_authorized_keys`,
`security`, `reboot_notify`, `firewall`, `podman`, `zerotier`, `beszel_agent`,
`forgejo_runner`. `container` is a helper. Not included: `restic_backup`,
`semaphore`, `caddy`, `cloudflare_dns`.

## Verify

```sh
/opt/homebrew/bin/yamllint .
ANSIBLE_CONFIG=<scratch>/ansible.cfg pipx run ansible-lint --profile production
ANSIBLE_CONFIG=<scratch>/ansible.cfg ansible-playbook -i inventories/production/hosts.yml site.yml --syntax-check
molecule test -s default          # common, ssh_authorized_keys, security (firewall omitted: see roles/firewall)
(cd roles/forgejo_runner && molecule test)   # forgejo_runner: renders Quadlet and config only
```

Last run (2026-10-17): yamllint clean, ansible-lint production profile passes,
`--syntax-check` passes. Molecule not run.
