# ops-de-wahlberger-dev Ansible Playbook

Single-host playbook targeting `ops.de.wahlberger.dev`, a Hetzner Cloud CX23
(x86_64) running **openSUSE Tumbleweed**. It hosts Semaphore UI, which applies
the nas, cloud and this playbook. The UI is reachable over ZeroTier only; TCP 22
is open to the internet, key-only. Modeled on `nas-de-int-wahlberger-dev` (see
its CLAUDE.md); roles are copied per playbook, not shared. `README.md` is also the
operator runbook for the Pi-to-VM migration: do not duplicate it here.

## Entry point & commands

- Playbook: `site.yml` (top-level). Default inventory is set in `ansible.cfg`.
  `site.yml` holds exactly the 15 roles of SH-FR-13, in that order, each tagged
  with its role name (SH-FR-143).
- Run: `ansible-playbook site.yml` (add `--check --diff` first, always). The vault
  password comes from 1Password via `.vault_pass.sh` (`ansible.cfg`'s
  `vault_password_file`).
- **No `ansible_host` in the inventory** (SH-D-17). Workstation runs pass
  `-e ansible_host=ops.de.int.wahlberger.dev` (or the public IP during bootstrap);
  otherwise they connect to the public name and trigger the public-login email.
- Roles a self-run excludes (`semaphore`, `zerotier`) are applied from the
  workstation only; see README "Roles a self-run excludes".
- Install deps first: `ansible-galaxy collection install -r requirements.yml`.
- Validate: `yamllint .`, `ansible-lint`, `ansible-playbook site.yml --syntax-check`.
- Idempotency: `molecule test` converges `common`, `notify_failure`, `disk_space`,
  `ssh_authorized_keys`, `security` twice on openSUSE Tumbleweed and fails on any
  change the second time.
- Static gate: `tests/static-checks.sh` runs every `[S]` scenario (`STATIC_CHECKS_ONLY=SH-AC-27`
  limits it to one id). `tests/pr-boundaries.sh <PR>` checks a pull request's file
  boundary. `tests/render-check.sh` renders templates (both designs) and verifies
  the Quadlets in a disposable container. `tests/guard-tests.sh` runs `tests/guards.d/`.
- **Never run tests, tools or `ansible-vault` with the cwd inside a playbook
  directory without `ANSIBLE_CONFIG` pointing elsewhere**: `ansible.cfg` calls
  `.vault_pass.sh`, which runs `op read` against the real 1Password item. The
  `tests/` and `tools/` helpers do this isolation themselves.
- Requirements and plan live outside this directory: `../semaphore-migration/reqs/`
  (IDs `SH-`) and `../semaphore-migration/PLAN.md`.

## Conventions (keep these when extending)

Same as the NAS playbook:

- **FQCN for every module**; ansible-core **2.16** on the workstation (`ansible.builtin.systemd`, not `systemd_service`).
- **Roles are self-contained**: `defaults/`, `tasks/`, `meta/main.yml`, `meta/argument_specs.yml`, `README.md`. No dependencies in `meta/main.yml`; order roles in `site.yml`.
- **Variables are role-prefixed**; the `container` role is a helper used through `include_role` and is not in `site.yml`.
- **Idempotent**; restart via change-notified handlers. **Lint target:** ansible-lint `production` profile.
- **openSUSE, not Debian**: `community.general.zypper`, sshd service is `sshd`, hand-rolled `security` role (no `geerlingguy.security`).
- **firewalld, not ufw**; Quadlets through the `container` role.

Deviations from the NAS copies (spec contract changes):

- **CC-07 `semaphore`** (vs the Pi's copy): new inputs `semaphore_require_existing_db`, `semaphore_uid` (empty by default; the role fails before any change while empty) and `semaphore_design` (`primary` | `bridge_fallback`). Primary joins `semaphore.network` (fixed subnet `semaphore_network_subnet`) and publishes `127.0.0.1:3000` only; the fallback joins `caddy.network` and publishes nothing. `config.json` is `0600` owned by the Semaphore UID, the data dir `0700`; `semaphore_data_dir` derives from `podman_data_dir`. The role never creates an empty database.
- **CC-08 `cloudflare_dns`**: new inputs `cloudflare_dns_extra_a_records` (empty fails the role), `cloudflare_dns_cname_target` (default `inventory_hostname`) and `cloudflare_dns_cnames_enabled` (production = `semaphore_dns_cutover_enabled`). Fails naming `vm_zt_ip` while it is empty. Never deletes records.
- **CC-09 `caddy`**: `Network=host`, `default_bind` on `caddy_bind_address` (= `vm_zt_ip`), `remote_ip` allowlist answering 403, no port-80 listener, no admin endpoint, access log with the client address, fails while `vm_zt_ip` is empty. New input `caddy_design`. Fallback: `caddy.network`, `PublishPort=<vm_zt_ip>:443:443`, upstream `semaphore:3000`.
- **CC-14 `security`**: sshd directives for key-only public SSH (`AuthenticationMethods publickey`, `AllowUsers`, `MaxAuthTries`, ...), `sshd -t` validation before any change and **reload, never restart**; new inputs `security_ssh_allow_users`, `security_fail2ban_findtime`, `security_fail2ban_ignoreip`; the public-login email hook; all account passwords locked; `zypper-dup` service and timer instead of the NAS's weekly `zypper patch`; rebootmgr strategy `maint-window` and an update script that never reboots by itself; a fail2ban ban action that adds no firewalld rich rule (`nftables-multiport`).
- **CC-15 `firewall`**: public zone `ssh` only; `vm_zt_iface` is bound by name, permanently, to zone `zerotier` (`ssh`, `https`, and `45876/tcp` from `cloud_zt_ip` by rich rule); input `firewall_zerotier_interface` (empty skips the zone with a message naming `vm_zt_iface`). Changes are permanent plus immediate and the role **never reloads or restarts firewalld**; the zone-creating run is permanent-only and needs an operator `firewall-cmd --reload` (README step 3).

## Stack

| Role | Purpose |
|------|---------|
| `common` | zypper refresh/upgrade (`common_upgrade`), baseline packages, timezone, hostname, persistent journal |
| `notify_failure` | Resend emails when a monitored unit's `OnFailure=` fires (`notify-failure@%n` flap-limited, `notify-failure-immediate@%n`). Monitored: `caddy`, `semaphore`, `zerotier`, `beszel-agent`, `restic-backup`, `zypper-dup`, `ssh-login-notify`, `disk-space-check` |
| `disk_space` | systemd timer; emails when `/` reaches 85 % |
| `ssh_authorized_keys` | Personal key, the automation key (with `from=`), and `ssh_authorized_keys_revoked`; a key in both lists fails the role before any change |
| `security` | sshd hardening, fail2ban, login email hook, locked passwords, weekly `zypper dup`, rebootmgr window, snapper |
| `reboot_notify` | Heads-up email before an update-triggered reboot (reuses `notify_failure`'s Resend credentials) |
| `firewall` | firewalld: public zone `ssh` only, ZeroTier zone bound by interface name |
| `podman` | Podman + Quadlet support, `/opt/podman` data dir (no separate mount: `podman_require_mountpoint: false`), image prune timer |
| `zerotier` | ZeroTier Quadlet (host network, `/dev/net/tun`); copied from cloud. Membership is authorized by hand in Central |
| `beszel_agent` | Native systemd Beszel agent, port 45876, hub on cloud |
| `cloudflare_dns` | A records `ops.de.wahlberger.dev` (public IP) and `ops.de.int.wahlberger.dev` (`vm_zt_ip`); the `semaphore` CNAME only after the cut-over flag |
| `caddy` | Custom-built Caddy (Cloudflare DNS module), DNS-01, host network bound to `vm_zt_ip`, `remote_ip` allowlist |
| `semaphore` | Semaphore UI Quadlet (SQLite), adopts a migrated database, Pocket ID OIDC |
| `restic_backup` | Daily 05:00 backup of a consistent SQLite copy to the NAS rest-server (repository `ops`); no forget/prune |
| `container` | Helper: renders one `.container` Quadlet and restarts on change. Not listed in `site.yml` |

## Data & secrets

- Persistent data under `/opt/podman` on the root filesystem (`caddy/`, `semaphore/`, ZeroTier identity). No separate data disk.
- Secrets: encrypted `inventories/production/group_vars/all/vault.yml`, exposed via `{{ vault_* | default('') }}` indirection in `vars.yml`; `vault.yml.example` is the key scaffold (9 keys). Never commit plaintext secrets, and never print them.
- Seven values are **copied verbatim from the Pi's Vault** because the migrated state depends on them: `vault_semaphore_access_key_encryption` (a different value makes every stored Key Store entry undecryptable, SH-C-05), `vault_semaphore_cookie_hash`, `vault_semaphore_cookie_encryption`, `vault_semaphore_oidc_client_secret` (the Pocket ID client does not change), `vault_semaphore_admin_password`, `vault_cloudflare_dns_api_token`, `vault_notify_failure_resend_api_key`. Two are **generated** (32 alphanumeric characters, URL-safe because the REST password sits in a `rest:http://user:PASSWORD@host` URL): `vault_restic_backup_repo_password`, `vault_restic_backup_rest_server_password`; they must equal the NAS's `vault_restic_server_ops_*` values (SH-BR-09). Build the Vault with `tools/populate-vault.sh`; compare with `tools/vault-hash-compare.sh` (hashes only).
- Never in the repository: the automation key's private half, any ZeroTier Central API token (SH-FR-205), `access_key_encryption` on the NAS (SH-BR-11), the ZeroTier identity in a backup (SH-FR-171).
- Values that exist only after a live step stay empty on purpose, and the roles that need them fail naming the variable: `vm_zt_ip` and `vm_zt_iface` (pull request A2), `cloud_zt_ip` (read from Central at OP-02, set together with `vm_zt_iface` in A2 because the `firewall` role fails otherwise; the spec Inputs table says "PR A", a documented deviation, see PLAN.md carry-over), `semaphore_uid` (pull request A3, now `1001`).
- `restic_backup_sqlite_required` is not set in `vars.yml` (the stopgap `false` was deleted by pull request A3), so the role default `true` applies from the step-5 apply; `tests/guards.d/vm_vars.yml` accepts the variable absent or false.
- Design selector: `vm_proxy_design` (`primary` | `bridge_fallback`), wired to `caddy_design` and `semaphore_design`; committed by pull request A3.
- The Pi is read-only until step 7 ends: no commit under `pi-de-int-wahlberger-dev/` (SH-FR-97). Renovate will be frozen for the Pi and for `roles/semaphore/defaults/main.yml` by `renovate.json` rules, added in PR A / T-19 (removed in pull requests E and D).

## File modes (VM)

| Path | Owner | Mode |
|---|---|---|
| `/opt/podman/semaphore` | root | 0755 |
| `/opt/podman/semaphore/data` | `semaphore_uid`:root | 0700 |
| `.../data/database.sqlite` (no `-wal`/`-shm`/`-journal` placed) | `semaphore_uid`:root | 0600 |
| `/opt/podman/semaphore/config.json` | `semaphore_uid`:root | 0600 |
| `/opt/podman/semaphore/semaphore.env` | root:root | 0600 |
| `/opt/podman/caddy/caddy.env` | root:root | 0600 |
| `/var/lib/restic-backup/restic-backup.env` (dir and staging dir 0700) | root:root | 0600 |

`database.sqlite` carries `container_file_t` after the container's first start (`:Z` mounts).
The Pi's copies are `config.json` 0644 and data dir 0777; the VM deliberately differs.

## Adding a containerized service

Create `roles/<svc>/` (underscore, not hyphen), a templated unit at
`roles/<svc>/templates/<svc>.container.j2`, then `include_role: container` with
`container_name` and `container_quadlet_src`. Adding a role to `site.yml` changes
SH-FR-13 (and `tests/static-checks.sh` SH-AC-01): that needs a spec amendment first.
Add `meta/argument_specs.yml` and a `README.md` for the role.

## Documentation map

- `README.md`: runbook (steps 0 to 9, pull requests, gates, rollbacks), Cloud Firewall, break-glass, restore, update policy, incident note.
- `docs/zerotier-flow-rules.md`: dated "before" and "in force" flow rules.
- `docs/spikes/`: measured facts (Semaphore image, `authorized_keys` `from=`, Caddy global options). Evidence is container-level, not the VM.
- `docs/security-review.md`: the pre-merge security review (written by its own task).
- `tools/README.md`: operator tooling for steps 4 and 6.
