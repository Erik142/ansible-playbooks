# cloud-wahlberger-dev

Ansible playbook for the Hetzner Cloud VM **`cloud.wahlberger.dev`** (Debian 13),
running a container stack on **Podman Quadlets**. Its main service is
**Pocket ID** (a passkey OIDC provider) behind a **Caddy** reverse proxy.

This playbook is intentionally built as a **reference design** for the other
playbooks in this repo. It follows current Ansible best practices so it can be
copied as a starting point: fully-qualified module names, self-contained roles
with documented variables and input validation, idempotent tasks, a clean
inventory layout, and linting wired up.

## Layout

```text
cloud-wahlberger-dev/
├── ansible.cfg                  # project-local Ansible settings
├── site.yml                     # top-level playbook (entry point)
├── requirements.yml             # Galaxy collections + roles to install
├── .ansible-lint                # lint config (production profile)
├── .yamllint                    # YAML style config
├── README.md / CLAUDE.md        # docs (human / AI agent)
├── inventories/
│   └── production/
│       ├── hosts.yml            # host & group *structure* only
│       └── group_vars/
│           └── all/
│               └── vars.yml     # variables for all hosts (vault.yml sits here too)
└── roles/
    ├── common/                  # baseline OS setup (apt, packages, timezone)
    ├── firewall/                # ufw host firewall (default-deny inbound)
    ├── podman/                  # Podman + Quadlet runtime
    ├── caddy/                   # reverse proxy + automatic HTTPS (shared network)
    ├── pocket_id/               # Pocket ID OIDC provider (the main service)
    ├── freshrss/                # FreshRSS aggregator, login via Pocket ID OIDC
    └── container/               # generic Quadlet (.container) deployer (helper)
# Plus external role geerlingguy.security (SSH hardening, fail2ban, auto-updates),
# installed from Galaxy via requirements.yml.

# Each role has the standard structure, e.g.:
#   roles/common/
#   ├── defaults/main.yml        # documented, overridable variables
#   ├── tasks/main.yml           # the work (FQCN, idempotent)
#   ├── meta/main.yml            # galaxy_info, no dependencies
#   ├── meta/argument_specs.yml  # validates inputs before running
#   └── README.md
```

## Prerequisites

- Ansible (ansible-core ≥ 2.15) on the control machine.
- SSH access to `cloud.wahlberger.dev` as `erikwahlberger` with `sudo` rights —
  escalation is enabled in `site.yml` (add `--ask-become-pass` if sudo needs a
  password). **Key-based SSH must work**: the `security` role disables password
  authentication.
- Galaxy collections and roles installed:

  ```sh
  ansible-galaxy collection install -r requirements.yml
  ansible-galaxy role install -r requirements.yml
  ```

## Usage

```sh
# Dry run — show what would change, with diffs.
ansible-playbook site.yml --check --diff

# Apply everything.
ansible-playbook site.yml

# Only one role.
ansible-playbook site.yml --tags podman

# Target a different environment (when you add inventories/staging/).
ansible-playbook -i inventories/staging/hosts.yml site.yml
```

`ansible.cfg` sets `inventories/production/hosts.yml` as the default inventory,
so `-i` is optional for production.

## Hardening

Baseline hardening runs on every play, before the container runtime:

- **Automatic security updates** — `unattended-upgrades` (via
  `geerlingguy.security`). Auto-reboot is **off**; reboot on your own schedule
  after kernel updates.
- **fail2ban** — bans IPs after repeated failed SSH logins.
- **SSH hardening** — root login and password authentication disabled
  (key-only). Port stays **22** (key-only + fail2ban is the real control; CIS
  doesn't require moving it).
- **Host firewall** — `ufw` (nftables backend), default-deny inbound, allowing
  only **22 / 80 / 443**. See [`roles/firewall/README.md`](roles/firewall/README.md).

Knobs live in `inventories/production/group_vars/all/vars.yml` (`security_*`) and
the `firewall` role defaults. To move SSH off 22, change `security_ssh_port` and
add the new port to `firewall_allowed_tcp_ports`.

### Don't lock yourself out / defense in depth

- Key-based SSH must already work (password auth is turned off). Verify after the
  first run: you can still `ssh erikwahlberger@cloud.wahlberger.dev`, and on the
  host `sudo sshd -T | grep -E 'permitrootlogin|passwordauthentication'` → `no`.
- Rootful Podman published ports bypass the host firewall's INPUT filter (they're
  DNAT'd through FORWARD). Add a **Hetzner Cloud Firewall** (free, at the edge)
  allowing only 22/80/443 as the authoritative ingress control.

## Services: Pocket ID + Caddy

The host's main job is **Pocket ID** (`roles/pocket_id`), a passkey OIDC provider,
served over HTTPS by **Caddy** (`roles/caddy`):

- Caddy publishes 80/443, terminates TLS (automatic Let's Encrypt via HTTP-01),
  and reverse-proxies `id.wahlberger.dev` → the `pocket-id` container on **1411**.
- Pocket ID is **not** published to the host; it's reached only over the shared
  `systemd-caddy` Podman network. Its data (SQLite DB + encryption key) lives in
  the `pocket-id` named volume (`/app/data`) — **back this up**.
- Routes are declared in `caddy_sites` (group_vars), not container labels. Add a
  service by appending `{ host, upstream }` and re-running — see
  [`roles/caddy/README.md`](roles/caddy/README.md).

**Before the first run:** point `id.wahlberger.dev` at the VM's public IP,
**DNS-only (grey cloud)** in Cloudflare, or HTTP-01 can't validate.
**After:** open `https://id.wahlberger.dev` and finish Pocket ID's admin setup.

## Adding a service

Services run as Podman Quadlet `.container` units. Create a service role, put a
templated unit in its `templates/` (e.g. `templates/<svc>.container.j2`), and
call the generic `container` helper from the role. The full walk-through is in
[`roles/container/README.md`](roles/container/README.md).

## Secrets with Ansible Vault

Never commit plaintext secrets. Keep them in an encrypted file alongside the
non-secret vars:

```sh
# Create / edit the encrypted secrets file.
ansible-vault create inventories/production/group_vars/all/vault.yml
ansible-vault edit   inventories/production/group_vars/all/vault.yml
```

Inside `vault.yml`, name everything with a `vault_` prefix:

```yaml
vault_cloudflare_api_token: "super-secret-token"
```

Then surface it under a friendly name in `vars.yml` (so roles never reference
`vault_*` directly):

```yaml
cloudflare_api_token: "{{ vault_cloudflare_api_token }}"
```

Run with the vault password:

```sh
# Default: ansible.cfg's vault_password_file points at .vault_pass.sh, which
# fetches the password from 1Password (op CLI, desktop app unlocked) — no
# flag needed.
/Users/erikwahlberger/.pyenv/versions/ansible-bind9-venv/bin/ansible-playbook site.yml

# Without 1Password, fall back to one of:
ansible-playbook site.yml --ask-vault-pass
echo 'my-vault-password' > .vault_pass && ansible-playbook site.yml --vault-password-file .vault_pass
```

## Linting & validation

```sh
yamllint .                       # YAML style
ansible-lint                     # best-practice rules (production profile)
ansible-playbook site.yml --syntax-check
```

## Best practices applied (and why)

- **FQCN everywhere** (`ansible.builtin.apt`, not `apt`) — avoids module name
  clashes between collections; required by ansible-lint's production profile.
- **Self-contained roles** with `defaults/`, `tasks/`, `meta/` — portable and
  reusable; user-facing variables live in `defaults/main.yml` (lowest
  precedence, easy to override).
- **Role-prefixed variables** (`common_*`, `podman_*`, `container_*`) — prevents
  collisions across roles.
- **Input validation** via `meta/argument_specs.yml` — fails fast with a clear
  message when a role is called with bad/missing parameters.
- **Idempotency** — only built-in modules (no `command`/`shell`), and restarts
  fire via change-notified handlers, so re-runs report no false changes.
- **No `meta` dependencies** — role order is explicit in `site.yml`, which keeps
  execution order obvious (and satisfies `meta-no-dependencies`).
- **Inventory by environment** — `inventories/production/`, with host/group
  *structure* separated from *variables* in `group_vars/`.
- **Secrets via Vault** — encrypted `vault.yml`, referenced indirectly.
- **Vetted community roles** — SSH/fail2ban/auto-updates use the maintained
  `geerlingguy.security` role (pinned in `requirements.yml`) instead of
  reinventing security-critical code.
- **Linting wired up** — `.yamllint` + `.ansible-lint` (production profile).

## References

- [Ansible — sample directory layout & best practices](https://docs.ansible.com/ansible/latest/tips_tricks/sample_setup.html)
- [Ansible role argument validation](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_reuse_roles.html#role-argument-validation)
- [ansible-lint profiles](https://ansible.readthedocs.io/projects/lint/profiles/)
- [Red Hat — Good Practices for Ansible](https://redhat-cop.github.io/automation-good-practices/)
- [geerlingguy.security role](https://github.com/geerlingguy/ansible-role-security)
- [Debian — UnattendedUpgrades](https://wiki.debian.org/UnattendedUpgrades)
