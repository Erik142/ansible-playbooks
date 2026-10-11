# Spike A-26: `ansible.posix.authorized_key` with a leading `from="..."` option

Date 2026-10-10. Spec: SH-A-26 (inputs to SH-FR-126, task T-04). Evidence level: container (opensuse/tumbleweed, python 3.13), ansible-core 2.16.3, ansible.posix 2.2.2. Nothing touched a real host.

## Method
```
docker run -d --name t03-a26 opensuse/tumbleweed:latest sleep 3600
docker exec t03-a26 sh -c 'zypper --non-interactive install --no-recommends python3; useradd -m tester'
# inventory: t03-a26 ansible_connection=community.docker.docker ansible_python_interpreter=/usr/bin/python3
# task (same shape as roles/ssh_authorized_keys/tasks/main.yml, one loop item):
- ansible.posix.authorized_key:
    user: tester
    key: 'from="<list>" ssh-ed25519 AAAA...(fake) spike-key'
    state: present
```
Four consecutive runs with the same key body; only the `from=` list changes between run 2 and 3.

## Result
| Run | `from=` list | Result | Stored line |
|---|---|---|---|
| 1 | `1.2.3.4,10.0.0.1` | changed=1 | `from="1.2.3.4,10.0.0.1" ssh-ed25519 AAAA... spike-key` (verbatim) |
| 2 | identical | changed=0 | unchanged |
| 3 | `1.2.3.4,10.243.0.5,172.20.0.0/24` | changed=1 | options replaced in place; file still has exactly 1 line |
| 4 | identical to 3 | changed=0 | unchanged |

Modes created by the module: `.ssh` 0700, `authorized_keys` 0600.

- The `from=` line is stored verbatim; a changed option list updates the existing entry in place (keyed on the key body); no duplicate line; idempotent.
- The current role has no `exclusive`, so an entry whose body is removed from the list is not deleted by this module call. Revocation (`ssh_authorized_keys_revoked`) needs `state: absent` items (T-04 scope, unchanged by this spike).

## Decision
A-26 holds: T-04 keeps the whole `from="..." ssh-ed25519 ...` line in `ssh_authorized_keys_list`; the `key_options` fallback is NOT needed. Caveat for T-04: do not mix both forms for one key (a line with `from=` plus `key_options` was not tested). Affects: T-04 (and the `from=` check in T-14).
