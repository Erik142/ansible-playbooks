# rpi-boras

Ansible playbook for a Raspberry Pi in Borås, Sweden: bind9 (DNS, via the
external [`bind9`](https://github.com/Erik142/ansible-role-bind9) role) and
isc-kea (DHCP with dynamic DNS updates). **Legacy** — not held to this repo's
"reference design" bar (see the root [`README.md`](../README.md)), and not
covered by CI lint checks (no `.ansible-lint`/`.yamllint` config).

## Secrets with Ansible Vault

TSIG key secrets (`bind9_ddns_key_*_secret` in `group_vars/all/vars.yml`)
live encrypted in `group_vars/all/vault.yml`. Scaffold and real key names are
in `vault.yml.example`. Create the real file with:

```sh
ansible-vault create group_vars/all/vault.yml
```

then run the playbook with `--ask-vault-pass` (or
`--vault-password-file .vault_pass`).

**These are shared secrets, not independently rotatable.** Each TSIG key in
`roles/bind9_docker/tasks/main.yml` is also held by another host — the VyOS
router in Gothenburg, or `cloud.wahlberger.dev` — for zone transfer/DDNS.
Changing a key here without updating it everywhere else that uses it at the
same time breaks replication silently. Rotating one is a coordinated,
multi-host change, not a single-file edit.

## Run

```sh
ansible-galaxy role install -r requirements.yml
ansible-playbook -i inventory/pi/inventory.yaml main.yml --ask-vault-pass --ask-become-pass
```
