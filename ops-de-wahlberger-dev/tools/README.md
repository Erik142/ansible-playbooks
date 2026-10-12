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
| `vault-pair-compare.sh <vault.yml>:<key> <vault.yml>:<key> [label]` or `--cloud-nas` | Two DIFFERENTLY-named keys in two vaults: prints `<label>: match` or `<label>: MISMATCH` (a missing key is a MISMATCH, stderr names the side). Each side splits on its last colon. See "Comparing differently-named keys". | 0 match, 1 MISMATCH, 2 error |
| `check-from-list.sh <repo> --vm-public-ip <ip> [--vm-zt-ip <ip>] [--sem-subnet <cidr>] [--extra <addr>]...` | AC-23: the `semaphore-automation@ops.de.wahlberger.dev` line is the same string in nas, cloud and `ops-de-wahlberger-dev`, and `from=` lists exactly the public IP, ZT IP, subnet plus extras (FR-191). ZT IP and subnet default to the VM `vars.yml`. | 0 ok, 1 failed, 2 input error |
| `populate-vault.sh [--replace-placeholder] [--force] [--regenerate-secrets] [--show-hash]` | T-12, ONCE, before PR A: builds the VM's real `group_vars/all/vault.yml` from `vault-manifest.yml`. See "Populating the VM Vault" below. | 0 all verified, 1 MISMATCH / bad format, 2 error, 3 refused to overwrite |
| `vault-copy-keys.sh <src.yml>:<src-key>=<dst-key>... --to <dst.yml> [--dry-run] [--force]` or `--ops-to-nas` | Step 5: COPIES values into differently-named keys of another existing vault (SH-BR-09, byte-identical secrets). Prints only `<dst-key>: copied, match` / `MISMATCH` / `already present, equal`. See "Copying keys between vaults". | 0 ok, 1 modified then restored (MISMATCH/failure), 2 error/refused (nothing written), 3 restore FAILED |

Tests: `cd ops-de-wahlberger-dev && pytest tests/tools -q` (needs `pytest`; the Docker
tests start a throwaway `semaphoreui/semaphore:v2.19.16` container named `t13-sem-*` and
are skipped with a stated reason when Docker, the image, or `ansible-vault` is missing).
Lint: `ruff check --config tools/ruff.toml tools tests/tools && shellcheck tools/*.sh`.

## Comparing differently-named keys (`vault-pair-compare.sh`)

Use it when the same secret lives under two names, e.g. the restic REST password:
`vault_restic_backup_rest_server_password` (cloud, client) must equal
`vault_restic_server_cloud_htpasswd_password` (NAS, server). Nothing but the verdict is printed.

```sh
# Convenience: both playbooks' default vault.yml (override: VAULT_CLOUD, VAULT_NAS)
ops-de-wahlberger-dev/tools/vault-pair-compare.sh --cloud-nas      # restic_rest_password: match
# Any pair; optional label, else "<keyA> vs <keyB>"
ops-de-wahlberger-dev/tools/vault-pair-compare.sh \
  cloud-wahlberger-dev/inventories/production/group_vars/all/vault.yml:vault_a \
  nas-de-int-wahlberger-dev/inventories/production/group_vars/all/vault.yml:vault_b my-label
```

Passwords: `VAULT_CLOUD_PASS_FILE` / `VAULT_NAS_PASS_FILE` (pair mode: `VAULT_LEFT_PASS_FILE` /
`VAULT_RIGHT_PASS_FILE`), else each playbook's `ansible.cfg` (`.vault_pass.sh`: unlock 1Password
first). Tests: `pytest tests/tools/test_vault_pair.py -q`.

## Copying keys between vaults (`vault-copy-keys.sh`)

Owner-run, with 1Password unlocked: without password files each playbook's `.vault_pass.sh`
fills the two vault passwords (source and destination). Step 5 of the ops migration:

```sh
ops-de-wahlberger-dev/tools/vault-copy-keys.sh --ops-to-nas --dry-run   # check, write nothing
ops-de-wahlberger-dev/tools/vault-copy-keys.sh --ops-to-nas
# generic form (specs may repeat; the source key is on the left of "="):
ops-de-wahlberger-dev/tools/vault-copy-keys.sh \
  ops-de-wahlberger-dev/inventories/production/group_vars/all/vault.yml:vault_a=vault_b --to \
  nas-de-int-wahlberger-dev/inventories/production/group_vars/all/vault.yml
```

`--ops-to-nas` copies `vault_restic_backup_rest_server_password` to
`vault_restic_server_ops_htpasswd_password` and `vault_restic_backup_repo_password` to
`vault_restic_server_ops_repo_password` (paths: both repo vaults, override `VAULT_OPS` / `VAULT_NAS`).

- The destination is decrypted (`ansible-vault decrypt --output -`, never an editor) and the
  new `key: "value"` line is APPENDED; comments, order and quoting stay byte-for-byte.
- A destination key that already exists with an equal value is reported
  `already present, equal` and the file is not touched; a different value is refused (exit 2)
  unless `--force`, which replaces only that key's line.
- A missing or empty source key is refused (message names the key only).
- PyYAML is REQUIRED (duplicate keys, document markers and the "all other keys unchanged"
  check depend on it). Only the ansible venv python has it
  (`$HOME/.pyenv/versions/ansible-bind9-venv/bin/python`): the script re-executes itself under
  that python when `python3` lacks PyYAML; otherwise it exits 2 with the hint. `VAULT_COPY_PYTHON`
  overrides the interpreter.
- Refused before anything is written (exit 2): a duplicate key anywhere (also quoted or
  `key : v` forms), a `---` that is not the single leading one or any `...`, more than one YAML
  document, an edit that would change any other key (e.g. a `|+` block without final newline),
  an existing key that is not a plain `key:` line (even with `--force`: edit by hand), an
  ansible-vault encrypt result that is not a real `$ANSIBLE_VAULT;` payload, an existing
  `<vault>.bak`, a missing `<playbook>/ansible.cfg` when no password file is given, and an
  EXECUTABLE password file (ansible would run it as a script).
- Write: re-encrypt with the destination password, then (1) save the original encrypted bytes to
  `<vault>.bak` (0600, git-ignored via `*.yml.bak`), (2) temp file in the same directory,
  fsync, original file mode, atomic rename, (3) decrypt the new file and require the plaintext to
  equal the intended one AND every copied value to equal its source by SHA-256. Only then is
  `<dst-key>: copied, match` printed and the `.bak` deleted.
- Any failure from the write on (mismatch, ansible-vault/1Password lock or timeout, Ctrl-C) restores
  the original bytes atomically and verifies them: "the vault file was modified and has been
  restored from the original bytes (verified)", exit 1, the `.bak` is KEPT (delete it before
  the next run). If even the restore fails the exit code is 3 and the message prints the recovery:
  `cp <vault>.bak <vault>` or `git checkout -- <vault>`.
- Each `ansible-vault` call gets exactly one secret source and a clean environment: with a
  password file it runs with an empty `ANSIBLE_CONFIG` (the playbook's `vault_password_file`
  would be a second secret); without, `ANSIBLE_CONFIG=<playbook>/ansible.cfg`. Inherited
  `ANSIBLE_CONFIG`, `ANSIBLE_VAULT_PASSWORD_FILE`, `ANSIBLE_VAULT_IDENTITY(_LIST)`,
  `ANSIBLE_VAULT_ID_MATCH`, `ANSIBLE_VAULT_ENCRYPT_SALT` are dropped; stdin is never a terminal.
- `ansible-vault` is run by ABSOLUTE path: first `shutil.which`, then the bin dir of the running
  python (the ansible venv when re-executed), then `$HOME/.pyenv/versions/ansible-bind9-venv/bin`;
  a candidate answering 127 (a pyenv shim of a version without the tool) is skipped. None found:
  "ansible-vault not found; put `$HOME/.pyenv/versions/ansible-bind9-venv/bin` on PATH", exit 2,
  nothing written. The child keeps the caller's `PATH` (a password script such as
  `.vault_pass.sh` needs `op`). `ANSIBLE_CONFIG` is passed as an absolute path.
- A symlinked vault path is followed: the real file is written (temp file next to it, `.bak`
  next to it), restored on failure, and the link stays a link. Relative vault arguments work from
  any cwd.
- Password files are limited to 4096 bytes (they pass through a pipe); a larger one is refused (exit 2).
- SIGINT, SIGTERM and SIGHUP are handled like Ctrl-C for the duration of the run: after the write
  started the original is restored (exit 1, "restored ... (verified)"); before it, the vault is untouched
  (exit 2).
- `--dry-run` decrypts and checks everything and writes nothing.
- Output is key names and match/MISMATCH only, never a value or hash. Passwords: env
  `VAULT_SRC_PASS_FILE` / `VAULT_DST_PASS_FILE` (`--ops-to-nas`: `VAULT_OPS_PASS_FILE` /
  `VAULT_NAS_PASS_FILE`), else each playbook's `ansible.cfg`; a password file is handed to
  `ansible-vault` through a pipe. stderr says where each password comes from.
- Afterwards commit the encrypted destination vault; tests: `pytest tests/tools/test_vault_copy_keys.py -q`.

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
