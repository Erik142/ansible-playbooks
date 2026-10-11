# Operator tooling for the Semaphore migration (steps 4 and 6)

Run by Erik on the workstation. Nothing here changes a live system: the API tools only
issue GETs after the login POST, `db-prepare.sh` edits a local COPY, the vault and key
checks read files. Python 3.9+ standard library only (PyYAML is used when present).
Secrets are never printed: credentials come from the environment, results are counts,
names, or `match`/`MISMATCH`.

| Tool | Use | Exit codes |
|---|---|---|
| `step4-record.py <base-url> > record.json` | Step 4, before the Pi stops (FR-53, AC-20): counts per kind (summed over every project), newest task id (max over each project's `/tasks`), active schedules. Needs `SEMAPHORE_USER` and `SEMAPHORE_PASSWORD`. | 0 ok, 2 error |
| `db-prepare.sh <copy>` | On the workstation copy of `database.sqlite` (copy `-wal` along, FR-176): checkpoint, `integrity_check` = ok, all schedules inactive, no `-wal/-shm/-journal` left (it leaves WAL mode to guarantee this), then lists access keys, API tokens, integrations and `pi.de.int.wahlberger.dev`, `pi-de-int-wahlberger-dev`, `/mnt/data` matches by name. Run it before placing the DB on the VM; keep the printed lists for the migration notes (AC-54). | 0 ok, 1 unusable copy, 2 usage |
| `compare-record.py <record.json> <vm-url>` | On the VM BEFORE any task runs (PA-2): every count and the newest task id must equal the record, and every VM schedule must be inactive. Same env credentials. | 0 equal, 1 differs (each difference printed), 2 error |
| `vault-hash-compare.sh <key>...` | AC-17: prints `<key>: match` or `<key>: MISMATCH` comparing the Pi and VM vaults. Env: `VAULT_PI`, `VAULT_VM`, `VAULT_PI_PASS_FILE`, `VAULT_VM_PASS_FILE` (defaults: both repo vaults, passwords from each playbook's `ansible.cfg`, i.e. unlock 1Password first). | 0 all match, 1 any MISMATCH, 2 error |
| `check-from-list.sh <repo> --vm-public-ip <ip> [--vm-zt-ip <ip>] [--sem-subnet <cidr>] [--extra <addr>]...` | AC-23: the `semaphore-automation@ops.de.wahlberger.dev` line is the same string in nas, cloud and `ops-de-wahlberger-dev`, and `from=` lists exactly the public IP, ZT IP, subnet plus extras (FR-191). ZT IP and subnet default to the VM `vars.yml`. | 0 ok, 1 failed, 2 input error |
| `populate-vault.sh [--replace-placeholder] [--force] [--regenerate-secrets] [--show-hash]` | T-12, ONCE, before PR A: builds the VM's real `group_vars/all/vault.yml` from `vault-manifest.yml`. See "Populating the VM Vault" below. | 0 all verified, 1 MISMATCH / bad format, 2 error, 3 refused to overwrite |

Tests: `cd ops-de-wahlberger-dev && pytest tests/tools -q` (needs `pytest`; the Docker
tests start a throwaway `semaphoreui/semaphore:v2.19.16` container named `t13-sem-*` and
are skipped with a stated reason when Docker, the image, or `ansible-vault` is missing).
Lint: `ruff check --config tools/ruff.toml tools tests/tools && shellcheck tools/*.sh`.

## Populating the VM Vault (`populate-vault.sh`, T-12)

Builds `ops-de-wahlberger-dev/inventories/production/group_vars/all/vault.yml` for real.
Nothing is typed or pasted: seven values are copied from the Pi's Vault and two are
generated, as listed in `vault-manifest.yml` (key -> `pi:<key>` or `generate:alnum32`):

| VM vault key | Source |
|---|---|
| `vault_semaphore_access_key_encryption` (FR-43), `vault_semaphore_cookie_hash` (FR-44), `vault_semaphore_cookie_encryption` (FR-146), `vault_semaphore_admin_password` (FR-46), `vault_semaphore_oidc_client_secret` (FR-201) | copied from `pi-de-int-wahlberger-dev` Vault, same key name |
| `vault_cloudflare_dns_api_token` (FR-147), `vault_notify_failure_resend_api_key` (FR-148) | copied from `pi-de-int-wahlberger-dev` Vault, same key name |
| `vault_restic_backup_repo_password`, `vault_restic_backup_rest_server_password` (BR-09) | generated, 32 characters `[A-Za-z0-9]` (the REST password goes unescaped into a `rest:http://user:PASSWORD@host` URL) |

How it works, and what it will not do:

- Source Vaults are read with `ansible-vault view` run from the SOURCE playbook directory, so
  that playbook's own `ansible.cfg` and `.vault_pass.sh` apply (this is the step that needs the
  1Password unlock for the Pi item).
- The VM Vault password is read with `op read "<reference>" --no-newline`; the reference is
  taken from `ops-de-wahlberger-dev/.vault_pass.sh` (one source of truth). The VM Vault is
  encrypted and re-read with that password through a pipe, in a scratch cwd with an empty
  `ANSIBLE_CONFIG`; plaintext never touches disk, argv or the environment.
- stdout has key names and `copied from pi:<key>` / `generated` / `kept` only, then per copied
  key `match` or `MISMATCH` (new vault re-read against a fresh read of the source) and `ok` for
  the generated format. `--show-hash` adds `sha256:<first 8 hex>` per key, for comparing by eye
  with `vault-hash-compare.sh`; off by default.
- Refuses (exit 3, file untouched) when `vault.yml` already holds a real vault, unless
  `--force`; refuses a file the VM password cannot decrypt (the throwaway placeholder from T-02)
  unless `--replace-placeholder`; refuses a plaintext file unless `--force`. Refuses (exit 2)
  before writing when any source key is missing or empty. With `--force` the existing generated
  passwords are KEPT (the NAS may already use them, T-20); `--regenerate-secrets` draws new ones.
- The result is written mode 0600 (temp file in the same directory, then rename).

Operator commands (workstation, 1Password unlocked, from the repository root; nothing else
needs a working directory because the tool resolves its own paths):

```sh
# 1. First run: replace the throwaway placeholder with the real vault
ops-de-wahlberger-dev/tools/populate-vault.sh --replace-placeholder
# 2. Optional: compare hashes by eye or with the Pi vault (values never printed)
ops-de-wahlberger-dev/tools/vault-hash-compare.sh \
  vault_semaphore_access_key_encryption vault_semaphore_cookie_hash \
  vault_semaphore_cookie_encryption vault_semaphore_oidc_client_secret \
  vault_semaphore_admin_password vault_cloudflare_dns_api_token \
  vault_notify_failure_resend_api_key
# 3. Check the file: a vault header and mode 0600
head -c 15 ops-de-wahlberger-dev/inventories/production/group_vars/all/vault.yml; echo
ls -l ops-de-wahlberger-dev/inventories/production/group_vars/all/vault.yml
# Re-run later (keeps the generated restic passwords): add --force
ops-de-wahlberger-dev/tools/populate-vault.sh --force
```

Expected: step 1 ends with `all verified` and nine key lines above it; step 2 prints seven
`match` lines; step 3 prints `$ANSIBLE_VAULT` and `-rw-------`. Keep a copy of the restic
repository password outside Vault, and give both generated passwords to T-20 (NAS side).
Tests (scratch playbook dirs, throwaway passwords, a fake `op`; the real 1Password and the real
Vaults are never touched): `pytest tests/tools/test_populate_vault.py -q`.
