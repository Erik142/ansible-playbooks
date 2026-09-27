# Requirements

---

## Feature: Replace Mealie with Tandoor Recipes on nas.de.int.wahlberger.dev
status:            ready
priority:          must
version:           1.3
quality-pillars:   5,5,5,5,5,5,5,5
quality-reviewed:  2026-09-27

### Problem Statement

The household recipe manager on nas.de.int.wahlberger.dev is Mealie. The owner has decided to switch to Tandoor Recipes. Tandoor's REST API accepts writes (`/api/recipe/`, Bearer-token auth), which a planned photo-to-recipe import workflow will depend on. The owner does not want two recipe managers running long-term, so Tandoor replaces Mealie at the same hostname, `recipes.de.int.wahlberger.dev`, in one playbook run. After the cut-over, Tandoor is the only recipe manager on the NAS. It is reachable over HTTPS with Pocket ID single sign-on, included in the nightly backup, shown on the Homepage dashboard, and deployed with the same conventions as the other container services on this host. Mealie holds 2 recipes today. The owner re-enters them by hand in Tandoor; no data migration is done.

Terms:
- **Cut-over run**: the first `ansible-playbook site.yml` run at the feature commit. In that one run Tandoor starts serving `https://recipes.de.int.wahlberger.dev`, and Mealie's unit, container, Caddy route and Homepage entry are removed from the host (Q2, option A).
- **Household space**: the single Tandoor space the owner creates at first sign-in. All recipes live in it. The owner is its admin.
- **Tandoor secrets**: `tandoor_secret_key` (Django secret key), `tandoor_db_password`, `tandoor_oidc_client_secret`.
- **Allowed user groups**: the Pocket ID setting on an OIDC client that lists which Pocket ID user groups can sign in through that client.
- **Rollback path**: `git revert` of the cut-over commit plus a `site.yml` run. It redeploys Mealie at `recipes.de.int.wahlberger.dev` with the data kept in `/mnt/containers/mealie` and Mealie's unchanged Pocket ID client (BR-01).

Constraints (given, not re-evaluated here):
- C-01: Product choice is Tandoor Recipes (github.com/TandoorRecipes/recipes). This is the owner's decision.
- C-02: Tandoor requires PostgreSQL. The repo's pattern for Postgres-backed services is a per-service Postgres container defined in the service's own role (`paperless_ngx` -> `paperless-db`, `immich` -> `immich-postgres`). It sits on a private per-service Podman network, reads its password from a 0600 env file, and is dumped nightly with `pg_dump` by `restic_backup`. No shared Postgres role exists. This feature follows the per-service pattern.
- C-03: The conventions in `nas-de-int-wahlberger-dev/CLAUDE.md` apply:
  - FQCN for every module; ansible-core 2.16 module names.
  - Self-contained role: `defaults/`, `tasks/`, `handlers/`, `meta/main.yml` with no dependencies, `meta/argument_specs.yml`, `README.md`. Every new role variable (including new `restic_backup_*` variables) is declared in its role's `argument_specs.yml`.
  - Role-prefixed variables (`tandoor_*`).
  - Quadlet units rendered through the shared `container` role.
  - ansible-lint `production` profile.
- C-04: Every secret lives in Ansible Vault (`vault_*` in `vault.yml`, surfaced in `vars.yml` with `| default('')`). The `password` lookup and `secret_files/` are not used.
- C-05: Pocket ID OIDC clients are registered by hand in the Pocket ID admin UI on cloud-wahlberger-dev. No Ansible-managed client configuration exists.

Primary flow (Q1 to Q5 decided by the owner on 2026-09-27):
1. The operator registers a new Pocket ID OIDC client for Tandoor (BR-09) with callback URL `https://recipes.de.int.wahlberger.dev/accounts/oidc/pocket-id/login/callback/`, and sets its allowed user groups to the household's Pocket ID group or groups (BR-08). The client ID goes into `vars.yml`; the client secret, a generated DB password and a generated secret key go into `vault.yml`.
2. The operator writes down the 2 Mealie recipes as a reference copy.
3. The operator runs the cut-over run. In that one run:
   - `tandoor-db` and `tandoor` start.
   - Caddy routes `recipes.de.int.wahlberger.dev` to `tandoor` instead of `mealie`.
   - Homepage lists Tandoor and no longer lists Mealie.
   - The Mealie unit and container are removed. `/mnt/containers/mealie` stays on disk (FR-46).
   - `restic_backup` dumps the Tandoor DB from the next nightly run on.
4. The owner signs in through Pocket ID before any other household user, creates the household space (and so becomes its admin, FR-48), re-enters the 2 recipes and runs the acceptance scenarios. Household users sign in after that and join the space as non-admin members (FR-22).
5. Once BR-01 is met, the owner deletes `/mnt/containers/mealie` with the manual `rm -rf` step in `roles/tandoor/README.md` (FR-43) and deletes Mealie's Pocket ID client (FR-44). Until then, the rollback path stays available.

Assumptions (non-blocking; upstream facts to verify during implementation, each detected by the scenario named):
- A-01: The Tandoor container serves HTTP on port 8080 (upstream default `TANDOOR_PORT`). That gives Caddy upstream `tandoor:8080` and Homepage check `http://tandoor:8080`. Verify against the pinned image; AC-22 and AC-24 detect a wrong port.
- A-02: `tandoor_image` is the official upstream image, pinned to the latest stable release at implementation time. Verify the registry and repository name from upstream docs (AC-05).
- A-03: `tandoor_db_image` is a `docker.io/library/postgres` major version that Tandoor's installation docs list as compatible at the pinned release. If major 18 is listed, use `postgres:18`, which shares image layers with `paperless-db`. AC-01 detects an incompatible major.
- A-04: `tandoor_oidc_provider_id` defaults to `pocket-id`, matching the Pocket ID Tandoor guide (pocket-id.org/docs/client-examples/tandoor-recipes). The callback is then `https://recipes.de.int.wahlberger.dev/accounts/oidc/pocket-id/login/callback/` (AC-14).
- A-05: Ansible does not create a local Tandoor account. Admin recovery uses `manage.py createsuperuser` inside the `tandoor` container, the same recovery path as paperless_ngx. Tandoor's local login form stays visible if upstream has no switch to hide it.
- A-06: Homepage v2.2.0's status check could send an HTTP request with `Host: tandoor`. If so, Tandoor's allowed-hosts setting must accept `tandoor` for the check to report "up". AC-24 detects a mismatch.
- A-07: Withdrawn. The values in NFR-03 to NFR-06 are owner-confirmed targets (Q5, 2026-09-27).
- A-08: The reasons recorded for switching are the owner's decision and the REST API import workflow. Other reasons do not change these FRs.
- A-09: Verified in the repo on 2026-09-27: the `podman` role enables `podman-image-prune.timer` (`podman_image_prune_enabled: true`, weekly, `podman_image_prune_min_age: 168h`). It removes the Mealie image once no container uses it, so no FR is needed.
- A-10: Verified in the repo on 2026-09-27: `roles/restic_backup/templates/restic-backup.service.j2` declares `OnFailure=notify-failure-immediate@%n.service`.
- A-11: Tandoor can keep local username/password registration closed (FR-21) while it still creates accounts at first Pocket ID sign-in (FR-19). Verify against the pinned release; AC-14 and AC-17 together detect a conflict. If the release cannot do both, implementation stops and the owner decides.
- A-12: Tandoor adds a new account to the household space only if that space exists when the account is created (FR-22). A user whose first sign-in comes before the space exists gets an account with no space membership. Verify against the pinned release; the remedy is the README step in FR-55.
- A-13: While no Tandoor user exists, Tandoor offers a first-user setup page (`{tandoor_url}/setup/`) that creates a local superuser. FR-21 applies to this page from the first deployment on (AC-48). Verify against the pinned release.

### Actors

| Actor | Human/System | Description |
|---|---|---|
| Owner/operator (Erik) | Human | Runs the playbook, manages Vault and Pocket ID clients, creates and administers the household space |
| Household user | Human | A Pocket ID user other than the owner who is in an allowed user group of the Tandoor client (BR-08). Gets a non-admin Tandoor account at first sign-in (FR-19, FR-47, FR-76) and joins the household space as a non-admin member (FR-22) |
| Ansible control node | System | Operator laptop or Semaphore UI on pi-de-int-wahlberger-dev. Runs `site.yml` with ansible-core 2.16; the Vault password comes from 1Password via `.vault_pass.sh` |
| NAS host | System | nas.de.int.wahlberger.dev: openSUSE Tumbleweed, rootful Podman + Quadlet, systemd, `/mnt/containers` data disk |
| `tandoor` container | System | Tandoor Recipes web app and REST API, unit `tandoor.service` |
| `tandoor-db` container | System | PostgreSQL database for Tandoor only, unit `tandoor-db.service` |
| Pocket ID | System | OIDC identity provider at `pocket_id_app_url` (`https://id.wahlberger.dev`), hosted on cloud-wahlberger-dev. Decides who can sign in to Tandoor through the Tandoor client's allowed user groups (BR-08) |
| Caddy | System | Reverse proxy container on `caddy.network`; TLS through Cloudflare DNS-01; routes configured from `caddy_sites` |
| Homepage | System | Dashboard container on `caddy.network`; shows a link and a status check per service |
| restic_backup | System | Nightly 03:00 oneshot job. Runs `pg_dump` on each Postgres container, then backs up `/mnt/containers` and the Samba share to pi-de-int-wahlberger-dev |
| notify_failure | System | Sends email through Resend when a unit's `OnFailure=` hook fires (default threshold: 5 failures in 10 min) |
| Future import client | System | Photo-to-recipe importer that will call the Tandoor REST API with a Bearer token (out of scope; FR-27 and FR-77 check it is possible) |

### Functional Requirements

#### Tandoor deployment (new role `roles/tandoor/`)
- FR-01 [Must]: The playbook shall run Tandoor Recipes as a Podman Quadlet container named `tandoor`, with unit `tandoor.service`, deployed through the shared `container` role.
- FR-62 [Must]: `tandoor.service` shall be wanted by `default.target`.
- FR-02 [Must]: The playbook shall run a PostgreSQL container named `tandoor-db`, with unit `tandoor-db.service`, as Tandoor's only database.
- FR-63 [Must]: `tandoor-db.service` shall be wanted by `default.target`.
- FR-03 [Must]: The `tandoor-db` container shall be attached only to a private Podman network named `tandoor`.
- FR-04 [Must]: The `tandoor` container shall be attached to exactly two Podman networks: the one created by `caddy.network`, and `tandoor`.
- FR-49 [Must]: The `tandoor-db` container shall publish no host port.
- FR-50 [Must]: The `tandoor` container shall publish no host port.
- FR-05 [Must]: `tandoor.service` shall declare `Requires=caddy-network.service`.
- FR-64 [Must]: `tandoor.service` shall declare `After=caddy-network.service`.
- FR-65 [Must]: `tandoor.service` shall declare `After=tandoor-db.service`.
- FR-06 [Must]: `tandoor.service` shall declare `OnFailure=notify-failure@%n.service`.
- FR-66 [Must]: `tandoor-db.service` shall declare `OnFailure=notify-failure@%n.service`.
- FR-07 [Must]: The Tandoor database cluster shall be stored in a host bind mount under `/mnt/containers/`, so it survives removal and re-creation of the `tandoor-db` container.
- FR-67 [Must]: Tandoor's uploaded media files shall be stored in a host bind mount under `/mnt/containers/`, so they survive removal and re-creation of the `tandoor` container.
- FR-08 [Must]: `roles/tandoor/defaults/main.yml` shall pin `tandoor_image` to an explicit version tag (not `latest`) on a single `tandoor_image: <registry/repo>:<tag>` line that the existing Renovate custom manager in `renovate.json` matches.
- FR-51 [Must]: `roles/tandoor/defaults/main.yml` shall pin `tandoor_db_image` to an explicit version tag (not `latest`) on a single `tandoor_db_image: <registry/repo>:<tag>` line that the existing Renovate custom manager in `renovate.json` matches.
- FR-09 [Must]: Every file on the NAS host that contains the value of a Tandoor secret shall have mode `0600` and owner `root:root`.
- FR-10 [Must]: No Tandoor secret value shall appear in any Quadlet unit file under `/etc/containers/systemd/`.
- FR-68 [Must]: No Tandoor secret value shall appear unencrypted in any file tracked in the Git repository.
- FR-11 [Must]: When a Tandoor env file changes during a run, the playbook shall restart the container that reads that file in the same run.
- FR-69 [Must]: When a Tandoor env file is created during a run on a host where the Quadlet unit of the container that reads it did not exist before that run, the playbook shall start that container in the same run (handler with daemon reload, as in `roles/paperless_ngx/handlers/main.yml`).
- FR-12 [Must]: If any of `tandoor_url`, `tandoor_oidc_client_id`, `tandoor_oidc_client_secret`, `tandoor_db_password` or `tandoor_secret_key` is empty, then the `tandoor` role shall fail before making any change on the host.
- FR-70 [Must]: When the `tandoor` role fails under FR-12, the failure message shall name every FR-12 variable that is empty.
- FR-71 [Must]: When the `tandoor` role fails under FR-12, the failure message shall contain the path `roles/tandoor/README.md`.
- FR-13 [Must]: `roles/tandoor/meta/argument_specs.yml` shall declare every variable in `roles/tandoor/defaults/main.yml` with `type` and `description`.
- FR-52 [Must]: `roles/tandoor/meta/argument_specs.yml` shall mark `tandoor_url` and `tandoor_oidc_client_id` with `required: true`.
- FR-14 [Must]: `roles/tandoor/README.md` shall contain a role variables section that names each input FR-12 requires to be non-empty. A secret can be identified by its `vault_tandoor_*` key instead of its `tandoor_*` name.
- FR-72 [Must]: The role variables section of `roles/tandoor/README.md` shall refer to `roles/tandoor/defaults/main.yml` for every role variable it does not name, as `roles/paperless_ngx/README.md` does.
- FR-53 [Must]: `roles/tandoor/README.md` shall document registering a new Pocket ID OIDC client that only Tandoor uses (BR-09).
- FR-73 [Must]: `roles/tandoor/README.md` shall state the exact callback URL to register for Tandoor's Pocket ID client (FR-17).
- FR-74 [Must]: `roles/tandoor/README.md` shall document setting the allowed user groups of Tandoor's Pocket ID client, which decide who can sign in (BR-08).
- FR-54 [Must]: `roles/tandoor/README.md` shall state that the owner creates the household space at the owner's first sign-in, before any other household user signs in.
- FR-55 [Must]: `roles/tandoor/README.md` shall document how the owner invites, by invite link, a user who signed in before the household space existed (A-12).
- FR-56 [Must]: `roles/tandoor/README.md` shall document local admin recovery with `manage.py createsuperuser` in the `tandoor` container (A-05).
- FR-57 [Must]: `roles/tandoor/README.md` shall document the manual procedure for rotating `vault_tandoor_db_password` (BR-04).
- FR-58 [Must]: `roles/tandoor/README.md` shall state the effect of rotating `vault_tandoor_secret_key` (BR-05).
- FR-59 [Must]: `roles/tandoor/README.md` shall state that a Postgres major-version upgrade of `tandoor-db` needs a dump and restore.
- FR-75 [Must]: `roles/tandoor/README.md` shall state that Renovate does not propose Postgres major-version bumps (existing `renovate.json` rule).
- FR-60 [Must]: `roles/tandoor/README.md` shall document deleting the Mealie data with `rm -rf /mnt/containers/mealie`, run as root on the NAS host only when BR-01 is met (FR-43).
- FR-61 [Must]: `roles/tandoor/README.md` shall document deleting Mealie's Pocket ID client, only when BR-01 is met (FR-44).
- FR-15 [Could]: The `tandoor` container shall run with timezone `tandoor_timezone` (default `Europe/Berlin`).

#### Sign-in with Pocket ID (OIDC)
- FR-16 [Must]: Tandoor's login page shall offer sign-in with Pocket ID, using the discovery document at `{pocket_id_app_url}/.well-known/openid-configuration`.
- FR-17 [Must]: When a user starts Pocket ID sign-in, Tandoor shall send Pocket ID the redirect URI `{tandoor_url}/accounts/oidc/{tandoor_oidc_provider_id}/login/callback/` with scheme `https`.
- FR-18 [Should]: When a user starts Pocket ID sign-in, the authorization request shall include a PKCE `code_challenge` with `code_challenge_method=S256` (same as `paperless_ngx`).
- FR-19 [Must]: When a Pocket ID user with no linked Tandoor account completes sign-in, Tandoor shall create exactly one Tandoor account linked to that Pocket ID identity, without an invite link or owner approval (Q1).
- FR-20 [Must]: When a Pocket ID user whose Tandoor account is already linked completes sign-in, Tandoor shall sign in to that account without creating another one.
- FR-21 [Must]: Tandoor shall not allow anyone to register a local username/password account.
- FR-22 [Should]: While the household space exists, when a newly provisioned Pocket ID user signs in, Tandoor shall add that user to the household space with a non-admin role, without an invite link (Q1).
- FR-47 [Must]: Every Tandoor account created through Pocket ID sign-in shall have no Django staff status (`is_staff` is `False`) (Q1).
- FR-76 [Must]: Every Tandoor account created through Pocket ID sign-in shall have no Django superuser status (`is_superuser` is `False`) (Q1).
- FR-48 [Must]: When the owner creates the household space, Tandoor shall give the owner the admin role in that space (Q1).

#### Reverse proxy, dashboard, API
- FR-23 [Must]: Caddy shall serve Tandoor over HTTPS at `tandoor_url` by reverse-proxying to the `tandoor` container, through the single `caddy_sites` entry defined by BR-03.
- FR-24 [Must]: When a signed-in user submits a form through `tandoor_url` (for example, saving a recipe), Tandoor shall accept the request without a CSRF verification failure (HTTP 403).
- FR-25 [Must]: The Homepage group `NAS (nas.de.int.wahlberger.dev)` shall contain an entry named `Tandoor` whose `href` is `tandoor_url`.
- FR-26 [Must]: The status check of the Tandoor Homepage entry shall target the `tandoor` container's address on the container network (`http://tandoor:<port>`), not `tandoor_url` (BR-06).
- FR-27 [Should]: Tandoor's REST API at `{tandoor_url}/api/recipe/` shall accept a create request authenticated with a Tandoor API Bearer token, without redirecting to Pocket ID.
- FR-77 [Should]: Tandoor's REST API at `{tandoor_url}/api/recipe/` shall accept a read request authenticated with a Tandoor API Bearer token, without redirecting to Pocket ID.

#### Secrets and wiring
- FR-28 [Must]: The encrypted `inventories/production/group_vars/all/vault.yml` shall contain the keys `vault_tandoor_secret_key`, `vault_tandoor_db_password` and `vault_tandoor_oidc_client_secret`.
- FR-29 [Must]: `vars.yml` shall expose each FR-28 key as `tandoor_secret_key`, `tandoor_db_password` and `tandoor_oidc_client_secret`, in the form `"{{ vault_<key> | default('') }}"`.
- FR-30 [Must]: `vault.yml.example` shall contain one `REPLACE-...` placeholder per FR-28 key.
- FR-78 [Must]: Each FR-30 placeholder in `vault.yml.example` shall have a comment that names the value's source (Pocket ID) or its generation command, in the style of the existing entries.
- FR-31 [Must]: `vars.yml` shall define `tandoor_url` and `tandoor_oidc_client_id`, plus any OIDC settings that differ from role defaults, in a `# --- Tandoor ---` section.
- FR-32 [Must]: `site.yml` shall list `- role: tandoor` after `caddy` and before `homepage` and `restic_backup`.
- FR-79 [Must]: The `tandoor` role entry in `site.yml` shall carry `tags: [tandoor]`.

#### Backup
- FR-33 [Must]: Each `restic-backup.service` run shall include, in the snapshot it creates, a `pg_dump` of the Tandoor database taken during that same run and written to `restic_backup_staging_dir`.
- FR-34 [Must]: The restic snapshot shall exclude Tandoor's raw Postgres data directory.
- FR-80 [Must]: The restic snapshot shall exclude the credentials file used for the Tandoor `pg_dump`.
- FR-35 [Must]: The restic snapshot shall include Tandoor's media files directory.
- FR-36 [Must]: If the Tandoor `pg_dump` fails, then `restic-backup.service` shall end in the failed state (the existing `set -eu` behaviour for the paperless and immich dumps).
- FR-81 [Must]: If the Tandoor `pg_dump` fails, then `restic-backup.service` shall create no restic snapshot in that run.

#### Mealie decommission
- FR-37 [Must]: When the playbook runs against a host that has `/etc/containers/systemd/mealie.container`, the playbook shall leave the host after the run with no `mealie.service` unit.
- FR-82 [Must]: When the playbook runs against a host that has `/etc/containers/systemd/mealie.container`, the playbook shall leave the host after the run with no Podman container named `mealie`.
- FR-38 [Must]: When the playbook runs against a host without `/etc/containers/systemd/mealie.container`, the Mealie decommission tasks shall report no change.
- FR-39 [Must]: The repository shall contain no `nas-de-int-wahlberger-dev/roles/mealie/` directory.
- FR-83 [Must]: `site.yml` shall contain no `mealie` role entry.
- FR-40 [Must]: `vars.yml` shall contain no `mealie_*` variable.
- FR-84 [Must]: `vars.yml` shall contain no `caddy_sites` entry with a `mealie:` upstream.
- FR-41 [Must]: `vault.yml` shall contain no `vault_mealie_oidc_client_secret` key.
- FR-85 [Must]: `vault.yml.example` shall contain no `vault_mealie_oidc_client_secret` key.
- FR-42 [Must]: `roles/homepage/templates/services.yaml.j2` shall contain no Mealie entry.
- FR-43 [Must]: When BR-01 is met, the owner shall delete `/mnt/containers/mealie` from the NAS host with the manual step documented in `roles/tandoor/README.md` (FR-60).
- FR-44 [Should]: When BR-01 is met, the owner shall delete Mealie's OIDC client (client ID `93041358-e45e-4e44-b838-3c758cfe4681`, callback `https://recipes.de.int.wahlberger.dev/login`) in the Pocket ID admin UI, with the manual step documented in `roles/tandoor/README.md` (FR-61).
- FR-45 [Should]: No file in `nas-de-int-wahlberger-dev/` other than this REQS.md shall describe Mealie as a service deployed on this host. Covered: README.md, CLAUDE.md, role READMEs, comments in `site.yml`, `vars.yml`, templates, and role task, handler and defaults files, and statements of how many secrets exist. Historical references to rpi-karlsruhe's Mealie in the migration notes are allowed.
- FR-46 [Must]: No playbook task shall create, modify or delete `/mnt/containers/mealie` or any path below it (Q3).

### Business Rules

- BR-01: BR-01 is met when both hold: (a) every acceptance scenario that verifies a `[Must]` FR, plus AC-46, has passed on the production host, except AC-36 (the deletion itself) and AC-47 (the failure drill); (b) the owner has confirmed that both former Mealie recipes exist in Tandoor. Until BR-01 is met, `/mnt/containers/mealie` and Mealie's Pocket ID client are kept, so the rollback path restores Mealie with its data.
- BR-02: Every Tandoor secret comes from Ansible Vault. A value generated at run time (`password` lookup, `secret_files/`) does not comply.
- BR-03: The host part of `tandoor_url` equals the `host` of exactly one `caddy_sites` entry, and that entry's upstream is `tandoor:<Tandoor HTTP port>` (A-01).
- BR-04: `POSTGRES_PASSWORD` only takes effect when the database cluster is first initialised. If `vault_tandoor_db_password` changes after the first deployment and the role password inside `tandoor-db` was not changed to the same value first, then `tandoor` cannot connect to its database. Rotation is a documented manual procedure (FR-57), not automated.
- BR-05: Changing `vault_tandoor_secret_key` ends every existing Tandoor session, so users must sign in again. Recipe data is unaffected.
- BR-06: A Homepage entry for a service on this NAS uses the public URL for `href` and the container-network address for its status check. This is the existing NAT-hairpin rule, applied to Tandoor.
- BR-07: The cut-over run switches `recipes.de.int.wahlberger.dev` from Mealie to Tandoor. When it completes successfully, Tandoor is the only recipe manager deployed on the NAS host (Q2, option A).
- BR-08: Who can sign in to Tandoor is decided only by the Tandoor client's allowed user groups in Pocket ID. A Pocket ID user outside those groups cannot sign in; a user inside them gets an account at first sign-in (FR-19). Tandoor applies no group or email allow-list of its own (Q1).
- BR-09: Tandoor uses a Pocket ID OIDC client registered for Tandoor only. `tandoor_oidc_client_id` never equals Mealie's client ID `93041358-e45e-4e44-b838-3c758cfe4681`, because Mealie's client stays unchanged as part of the rollback path until BR-01 is met (Q4).

### Inputs

| Name | Type | Required | Constraints |
|---|---|---|---|
| `tandoor_url` | str (URL) | yes | Scheme `https`, no trailing slash; host satisfies BR-03; production value `https://recipes.de.int.wahlberger.dev` (Mealie's former hostname, Q2); role default empty (FR-12) |
| `tandoor_oidc_client_id` | str (UUID) | yes | Issued by Pocket ID for the client registered for Tandoor only; not equal to `93041358-e45e-4e44-b838-3c758cfe4681` (BR-09); plaintext in `vars.yml` |
| `tandoor_oidc_client_secret` | str | yes | From `vault_tandoor_oidc_client_secret`; non-empty; issued by Pocket ID for the Tandoor client (BR-09) |
| `tandoor_db_password` | str | yes | From `vault_tandoor_db_password`; 48 lowercase hex characters (`openssl rand -hex 24`, as for existing DB passwords), so it can appear in env files without quoting |
| `tandoor_secret_key` | str | yes | From `vault_tandoor_secret_key`; >= 50 characters of `[A-Za-z0-9]`; generation command documented in `vault.yml.example` |
| `tandoor_oidc_provider_id` | str | no | Default `pocket-id` (A-04); matches `^[a-z0-9-]+$`; part of the callback URL |
| `tandoor_oidc_provider_name` | str | no | Default `Pocket ID`; label on the login button |
| `tandoor_image` | str | no | `<registry/repo>:<version>`, explicit version tag (FR-08, A-02) |
| `tandoor_db_image` | str | no | `docker.io/library/postgres:<major>` (FR-51, A-03) |
| `tandoor_data_dir` | path | no | Default `/mnt/containers/tandoor`; holds media and the app env file |
| `tandoor_db_data_dir_root` / `tandoor_db_data_dir` | path | no | Default `/mnt/containers/tandoor-db` and `.../pgdata` (same layout as paperless_ngx) |
| `tandoor_timezone` | str | no | IANA zone name; default `Europe/Berlin` |
| `pocket_id_app_url` | str (URL) | yes (exists) | Shared issuer `https://id.wahlberger.dev`; not changed by this feature |

### Outputs

| Name | Type | Constraints |
|---|---|---|
| `/etc/containers/systemd/tandoor.container`, `tandoor-db.container` | Quadlet unit files | Mode `0644 root:root`; contain no secret value (FR-10) |
| `tandoor.service`, `tandoor-db.service` | systemd units | Active after the run; wanted by `default.target`; `OnFailure=notify-failure@%n.service` |
| Tandoor and tandoor-db env files | Files | Mode `0600 root:root` (FR-09) |
| Podman network `tandoor` | Network | Members: `tandoor`, `tandoor-db` only |
| HTTPS endpoint `tandoor_url` | Web UI | Valid public TLS certificate from Caddy; HTTP 200 or 302 (NFR-03) |
| REST API `{tandoor_url}/api/` | HTTP JSON API | Bearer-token auth (FR-27, FR-77) |
| Homepage `Tandoor` entry | Dashboard tile | `href` = `tandoor_url`; status check = `http://tandoor:<port>` |
| Tandoor SQL dump file in `restic_backup_staging_dir` | SQL dump | One file, rewritten each nightly run and included in that run's snapshot; the file name is an implementation choice |
| Failure email | Email via Resend | Sent by notify_failure for `tandoor`/`tandoor-db` crash loops and failed backup runs |

### Error Cases

| Condition | Expected behaviour |
|---|---|
| A required Tandoor variable is empty, or `vault.yml` lacks a Tandoor key | The role fails at its first task, naming the variable and `roles/tandoor/README.md`; nothing changes on the host (FR-12, FR-70, FR-71) |
| Vault password cannot be retrieved (1Password locked or unavailable) | The play aborts during variable decryption before any host task runs (existing behaviour) |
| The cut-over run fails partway (for example, the Tandoor image pull fails) | The play stops at the failing task with `failed=1`. `/mnt/containers/mealie` is unchanged (FR-46). After the cause is fixed, the next `site.yml` run completes the cut-over (AC-47); the rollback path is the alternative (BR-01) |
| `tandoor-db` does not accept connections yet when `tandoor` starts (first initdb, boot race) | `tandoor` exits and `Restart=always` restarts it. Tandoor becomes reachable within NFR-03/NFR-05 without manual action |
| `tandoor-db` restarts while `tandoor` is running | Tandoor serves pages again within 120 s without a manual restart of `tandoor.service` (NFR-04) |
| `tandoor` or `tandoor-db` crash-loops (corrupt data, bad image, full disk) | `Restart=always` keeps retrying. notify_failure sends an email after 5 failures within 10 min. Caddy returns HTTP 502 at `tandoor_url` and the Homepage status shows down |
| Image pull fails (registry unreachable) during deploy or upgrade | The unit fails to start and the play fails at that restart. The failure email follows the crash-loop rule above; the next successful run recovers |
| Pocket ID unreachable | The sign-in attempt shows an error page and no account is created. Sessions already signed in keep working until they expire; `tandoor.service` stays active |
| Redirect URI registered in Pocket ID does not match FR-17, or the client secret is wrong | Pocket ID rejects the request or the token exchange; no Tandoor account is created. The README lists the exact callback URL (FR-73) |
| Pocket ID user is in none of the Tandoor client's allowed user groups | Pocket ID refuses the authorization and returns no authorization code to Tandoor; no Tandoor account is created (BR-08, AC-46) |
| A household user signs in before the owner has created the household space | The user gets a Tandoor account (FR-19) with no space membership and no access to household recipes (A-12). The owner invites the user to the household space with the README step (FR-55) |
| While no Tandoor user exists, a client opens the first-user setup page (`{tandoor_url}/setup/`) | No account is created (FR-21, A-13, AC-48) |
| Same Pocket ID user signs in twice, in parallel tabs, or replays a callback (back button, double submit) | At most one Tandoor account per Pocket ID identity (FR-20). A replayed callback fails state validation with an error page, and a fresh sign-in succeeds |
| Local self-registration is attempted | No account is created (FR-21) |
| `/mnt/containers` fills up | The existing `disk_space` alert emails at its threshold. Postgres writes fail and Tandoor shows an error on save; no new behaviour is required |
| Tandoor `pg_dump` fails in the nightly backup | `restic-backup.service` fails, no snapshot is created, and the immediate failure email is sent (FR-36, FR-81, A-10) |
| `vault_tandoor_db_password` is rotated without the README procedure | `tandoor` cannot connect, which causes a crash-loop email. Fix: the documented manual `ALTER ROLE` (BR-04) |
| `vault_tandoor_secret_key` is rotated | All sessions end and users sign in again; data unaffected (BR-05) |
| Playbook runs against a host that still runs Mealie | Mealie unit and container are removed (FR-37, FR-82); `/mnt/containers/mealie` is kept (FR-46) |
| Playbook runs against a host without Mealie | Decommission tasks report no change (FR-38) |
| Host reboots (rebootmgr patch reboot, power loss) | Both units start at boot with no manual action (NFR-05) |
| Renovate proposes a Postgres major version bump | Disabled by the existing `renovate.json` rule (FR-75); a major upgrade needs a manual dump/restore (FR-59) |
| Playbook runs twice in a row with no input change | Second run reports `changed=0` (NFR-01) |

### Acceptance Criteria

Scenario AC-01: First deployment starts Tandoor and its database (FR-01, FR-02, FR-62, FR-63, NFR-03)
- Given the NAS host has no `tandoor.container` or `tandoor-db.container`, `vault.yml` holds the three Tandoor secrets, and `tandoor_url` is `https://recipes.de.int.wahlberger.dev`
- When the operator runs `ansible-playbook site.yml`
- Then the play recap shows `failed=0` for the host
- And `systemctl is-active tandoor.service` prints `active` (FR-01)
- And `systemctl is-active tandoor-db.service` prints `active` (FR-02)
- And `systemctl show -p WantedBy --value tandoor.service` lists `default.target` (FR-62)
- And `systemctl show -p WantedBy --value tandoor-db.service` lists `default.target` (FR-63)
- And within 300 s after the play ends, `curl -so /dev/null -w '%{http_code}' https://recipes.de.int.wahlberger.dev/` from a LAN client prints `200` or `302` (NFR-03)

Scenario Outline AC-02: Each Tandoor container is attached only to its specified networks (FR-03, FR-04)
- Given Tandoor is deployed
- When the operator lists the networks of `<container>` with `podman inspect`
- Then the listed networks are exactly `<networks>`
- Examples (one test per row): `tandoor-db` -> `tandoor` (FR-03); `tandoor` -> the network created by `caddy.network`, and `tandoor` (FR-04)

Scenario Outline AC-03: Each unit declares its dependency and failure-hook directives (FR-05, FR-64, FR-65, FR-06, FR-66)
- Given Tandoor is deployed
- When the operator runs `systemctl show <unit> -p <property> --value`
- Then the output `<expectation>`
- Examples (one test per row; `%n` expands to the full unit name, so the hook instance ends in `.service.service`):

| Requirement | `<unit>` | `<property>` | `<expectation>` |
|---|---|---|---|
| FR-05 | `tandoor.service` | `Requires` | contains `caddy-network.service` |
| FR-64 | `tandoor.service` | `After` | contains `caddy-network.service` |
| FR-65 | `tandoor.service` | `After` | contains `tandoor-db.service` |
| FR-06 | `tandoor.service` | `OnFailure` | equals `notify-failure@tandoor.service.service` |
| FR-66 | `tandoor-db.service` | `OnFailure` | equals `notify-failure@tandoor-db.service.service` |

Scenario Outline AC-04: Each data set survives re-creation of its container (FR-07, FR-67)
- Given a recipe named "AC-04 persistence" with an uploaded image exists in the household space
- When the operator runs `podman rm -f <container>` and then `systemctl start <container>.service`
- Then within 120 s, `<evidence>` is shown at `tandoor_url`
- And `podman inspect <container> --format '{{range .Mounts}}{{.Type}} {{.Source}}{{"\n"}}{{end}}'` lists a `bind` mount whose source is `<host path>` or a path below it
- Examples (one test per row):

| Requirement | `<container>` | `<evidence>` | `<host path>` |
|---|---|---|---|
| FR-07 | `tandoor-db` | the recipe "AC-04 persistence" | `tandoor_db_data_dir` (default `/mnt/containers/tandoor-db/pgdata`) |
| FR-67 | `tandoor` | the uploaded image of the recipe "AC-04 persistence" | `tandoor_data_dir` (default `/mnt/containers/tandoor`) |

Scenario Outline AC-05: Image pinned and Renovate-detectable (FR-08, FR-51)
- Given `roles/tandoor/defaults/main.yml`
- When the operator checks the `<variable>` line against the Renovate custom-manager regex in `renovate.json`
- Then the line matches
- And its tag is not `latest`
- Examples (one test per row): `tandoor_image` (FR-08), `tandoor_db_image` (FR-51)

Scenario AC-06: Secret-bearing files are root-only (FR-09)
- Given Tandoor and restic_backup are deployed
- When the operator, as root, lists every file under `/mnt/containers`, `/etc/containers/systemd` and `restic_backup_staging_dir` that contains the value of a Tandoor secret (`grep -rlF`, once per secret), and runs `stat -c '%a %U:%G'` on each
- Then every listed file shows `600 root:root`

Scenario Outline AC-07: No Tandoor secret value in `<location>` (FR-10, FR-68)
- Given Tandoor is deployed
- When the operator runs `<search>` once per Tandoor secret value
- Then every search returns 0 matches
- Examples (one test per row): Quadlet unit files on the NAS host, `grep -rlF '<value>' /etc/containers/systemd/` (FR-10); files tracked in Git at the feature commit, `git grep -lF '<value>'` (FR-68; the encrypted `vault.yml` holds ciphertext only)

Scenario AC-08: First-run handler works without a pre-existing unit (FR-69)
- Given a host where no Tandoor unit has ever existed
- When the operator runs `ansible-playbook site.yml --tags tandoor` once
- Then no task fails with "Could not find the requested service"
- And `tandoor.service` is active at the end of the play

Scenario AC-09: Changing the env file restarts only the container that reads it (FR-11)
- Given Tandoor is deployed and running, and the operator notes `ActiveEnterTimestamp` for both units
- When the operator changes `tandoor_oidc_provider_name` in `vars.yml` and runs `ansible-playbook site.yml --tags tandoor`
- Then `tandoor.service` has a later `ActiveEnterTimestamp` than before
- And `tandoor-db.service` has the same `ActiveEnterTimestamp` as before

Scenario Outline AC-10: A missing input fails before any change (FR-12, FR-70, FR-71)
- Given `<variable>` evaluates to an empty string
- When the operator runs `ansible-playbook site.yml --tags tandoor --diff`
- Then the play fails at the tandoor validation task (FR-12)
- And no task of the tandoor role reports `changed` before the failure (FR-12)
- And the failure message contains `<variable>` (FR-70)
- And the failure message contains `roles/tandoor/README.md` (FR-71)
- Examples: `tandoor_url`, `tandoor_oidc_client_id`, `tandoor_oidc_client_secret`, `tandoor_db_password`, `tandoor_secret_key`

Scenario AC-11: Argument specs declare every default (FR-13)
- Given `roles/tandoor/defaults/main.yml` and `roles/tandoor/meta/argument_specs.yml`
- When the operator compares the variable names in the two files
- Then every defaults variable appears in `argument_specs.yml` with `type` and `description`

Scenario Outline AC-12: README documents one operations item (FR-14, FR-53 to FR-61, FR-72 to FR-75)
- Given `roles/tandoor/README.md` at the feature commit
- When the operator reads the README
- Then the README contains `<required content>`
- Examples (one test per row; a missing item fails only its own row):

| Requirement | `<required content>` |
|---|---|
| FR-14 | A role variables section that names `tandoor_url` and `tandoor_oidc_client_id`, and names `tandoor_oidc_client_secret`, `tandoor_db_password` and `tandoor_secret_key` or the `vault_tandoor_*` key of each |
| FR-72 | In that role variables section, a reference to `roles/tandoor/defaults/main.yml` for the variables the section does not name |
| FR-53 | Steps to register a new Pocket ID OIDC client used by Tandoor only |
| FR-73 | The callback URL `https://recipes.de.int.wahlberger.dev/accounts/oidc/pocket-id/login/callback/` (FR-17's URL with the configured values filled in) |
| FR-74 | A step that sets the Tandoor client's allowed user groups in Pocket ID |
| FR-54 | The statement that the owner creates the household space at the owner's first sign-in, before any other household user signs in |
| FR-55 | Steps for the owner to invite, by invite link, a user who signed in before the household space existed |
| FR-56 | The command `manage.py createsuperuser`, run in the `tandoor` container |
| FR-57 | The rotation steps in the order AC-42 uses: change the role password inside `tandoor-db`, then update `vault_tandoor_db_password`, then run `site.yml --tags tandoor,restic_backup` |
| FR-58 | The statement that changing `vault_tandoor_secret_key` ends every Tandoor session and leaves recipe data unchanged |
| FR-59 | The statement that a Postgres major-version upgrade of `tandoor-db` needs a dump and restore |
| FR-75 | The statement that Renovate does not propose Postgres major-version bumps |
| FR-60 | The command `rm -rf /mnt/containers/mealie`, run as root on the NAS host, with BR-01 conditions (a) and (b) as its precondition |
| FR-61 | Steps to delete Mealie's Pocket ID client (client ID `93041358-e45e-4e44-b838-3c758cfe4681`) in the Pocket ID admin UI, with BR-01 conditions (a) and (b) as their precondition |

Scenario AC-13: Container timezone (FR-15)
- Given Tandoor is deployed with the default `tandoor_timezone`
- When the operator runs `podman exec tandoor date +%Z`
- Then the output is `CET` or `CEST`

Scenario AC-14: Owner signs in through Pocket ID for the first time (FR-16, FR-17, FR-19, FR-47, FR-76)
- Given the owner has a Pocket ID account in an allowed user group of the Tandoor client, and no Tandoor account exists
- When the owner opens `{tandoor_url}/accounts/login/` and selects the "Pocket ID" sign-in button
- Then the browser is redirected to an authorization URL on `https://id.wahlberger.dev` (FR-16)
- And the authorization URL's URL-decoded `redirect_uri` equals `https://recipes.de.int.wahlberger.dev/accounts/oidc/pocket-id/login/callback/` (FR-17)
- And after passkey authentication the owner lands in Tandoor signed in (FR-19)
- And exactly 1 Tandoor account is linked to the owner's Pocket ID identity, per `manage.py shell` in the `tandoor` container (FR-19)
- And that account has `is_staff` `False` (FR-47)
- And that account has `is_superuser` `False` (FR-76)

Scenario AC-15: PKCE in the authorization request (FR-18)
- Given the owner is signed out
- When the owner starts Pocket ID sign-in and the operator captures the authorization URL
- Then the URL contains a `code_challenge` parameter and `code_challenge_method=S256`

Scenario AC-16: A repeat sign-in creates no duplicate account (FR-20)
- Given the owner has signed in once before (AC-14)
- When the owner signs out, signs in again through Pocket ID, and also signs in from a second browser at the same time
- Then the number of Tandoor accounts linked to the owner's Pocket ID identity is still 1

Scenario AC-17: Local self-registration is closed (FR-21)
- Given the operator notes the Tandoor user count
- When an unauthenticated client opens `{tandoor_url}/accounts/signup/` and tries to register a username/password account
- Then no registration form accepts the submission
- And the Tandoor user count is unchanged

Scenario AC-18: Owner creates the household space at first sign-in (FR-48)
- Given no Tandoor space exists and the owner signed in for the first time (AC-14)
- When the owner follows Tandoor's first-login flow and creates a space named "Household"
- Then the space exists
- And the owner has the admin role in it

Scenario AC-19: A household user joins the space automatically (FR-19, FR-22, FR-47, FR-76, BR-08)
- Given the household space exists, and a second Pocket ID user who is in an allowed user group of the Tandoor client has never signed in to Tandoor
- When that user signs in through Pocket ID
- Then the user sees the household space's recipes without using an invite link (FR-19, FR-22)
- And the user's role in the household space is not admin (FR-22)
- And the user's account has `is_staff` `False` (FR-47)
- And the user's account has `is_superuser` `False` (FR-76)

Scenario AC-20: Pocket ID is unreachable (error case: dependency failure)
- Given the owner is signed in to Tandoor in browser A, and Pocket ID is unreachable (for example, during a Pocket ID maintenance window)
- When a user in browser B tries to sign in through Pocket ID
- Then browser B shows an error page, not a Tandoor session
- And the Tandoor user count is unchanged
- And browser A still loads recipes
- And `tandoor.service` is still active

Scenario AC-21: Redirect URI mismatch is rejected (error case: misconfiguration)
- Given the Pocket ID client's callback URL is temporarily set to a path different from FR-17
- When a user tries to sign in through Pocket ID
- Then Pocket ID shows an error and does not return an authorization code
- And no Tandoor account is created
- And the operator restores the correct callback URL afterwards

Scenario AC-22: HTTPS through Caddy at Mealie's former hostname (FR-23, BR-03, BR-07)
- Given the cut-over run has completed
- When a LAN client runs `curl -sI https://recipes.de.int.wahlberger.dev/` without `-k`
- Then TLS verification succeeds
- And the response status is 200 or 302
- And for a 302, the `Location` target is on host `recipes.de.int.wahlberger.dev` (a relative path, or an absolute URL with that host)
- And `caddy_sites` has exactly one entry with host `recipes.de.int.wahlberger.dev`, whose upstream is `tandoor:<port>`

Scenario AC-23: Saving through the proxy passes CSRF checks (FR-24)
- Given the owner is signed in at `tandoor_url`
- When the owner creates and saves a recipe named "AC-23 csrf" in the web UI
- Then the recipe is saved and listed
- And no response in the browser's network log has status 403 or the text "CSRF verification failed"

Scenario AC-24: Homepage entry and status (FR-25, FR-26, FR-42, BR-06)
- Given Homepage and Tandoor are deployed and `tandoor.service` is active
- When the owner opens `homepage_url`
- Then the group `NAS (nas.de.int.wahlberger.dev)` contains an entry "Tandoor" linking to `tandoor_url`
- And its status indicator shows up
- And the page shows no entry named "Mealie"
- And the rendered `services.yaml` on the host has the status check `http://tandoor:<port>`

Scenario AC-25: Tandoor down is visible (FR-26; error case: container stopped)
- Given Homepage is deployed
- When the operator runs `systemctl stop tandoor.service` and reloads the Homepage page
- Then the Tandoor status indicator shows down
- And `curl -so /dev/null -w '%{http_code}' https://recipes.de.int.wahlberger.dev/` prints `502`
- And after `systemctl start tandoor.service`, the indicator shows up again within 120 s

Scenario AC-26: REST API accepts a token-authenticated create request (FR-27)
- Given the owner has created a Tandoor API token
- When a client sends `POST {tandoor_url}/api/recipe/` with header `Authorization: Bearer <token>` and a body creating a recipe named "AC-26 api"
- Then the response status is 201
- And "AC-26 api" is listed in the web UI

Scenario AC-27: Vault and vars wiring (FR-28, FR-29, FR-30, FR-78, FR-31, BR-02, BR-09)
- Given the repository at the feature commit
- When the operator runs `ansible-vault view .../vault.yml` and inspects `vars.yml` and `vault.yml.example`
- Then `vault.yml` contains exactly the three `vault_tandoor_*` keys from FR-28 (FR-28, BR-02)
- And `vars.yml` contains the three `tandoor_*` secrets as `| default('')` indirections (FR-29)
- And `vars.yml` contains `tandoor_url` and `tandoor_oidc_client_id` under `# --- Tandoor ---` (FR-31)
- And `tandoor_oidc_client_id` is not `93041358-e45e-4e44-b838-3c758cfe4681` (BR-09)
- And `vault.yml.example` has a `REPLACE-...` placeholder for each of the three keys (FR-30)
- And each of those placeholders has a comment naming its source (Pocket ID) or its generation command (FR-78)

Scenario AC-28: Role order and tag in site.yml (FR-32, FR-79)
- Given `site.yml`
- When the operator runs `ansible-playbook site.yml --list-tasks`
- Then tandoor tasks appear after caddy tasks and before homepage and restic_backup tasks (FR-32)
- And `ansible-playbook site.yml --tags tandoor --list-tasks` lists the tandoor role's tasks (FR-79)

Scenario AC-29: Nightly backup contains the Tandoor DB dump and media (FR-33, FR-35, NFR-07)
- Given a recipe named "AC-29 backup" with an uploaded image exists
- When the operator runs `systemctl start restic-backup.service` and it completes
- Then `restic ls latest` lists the Tandoor dump file in `restic_backup_staging_dir` and the image file under Tandoor's media directory
- And `restic dump latest <dump path> | grep -c "AC-29 backup"` prints a number >= 1

Scenario Outline AC-30: A backup exclusion keeps `<item>` out of the snapshot (FR-34, FR-80)
- Given the backup from AC-29
- When the operator runs `restic ls latest`
- Then no listed path is `<path>` or below it
- Examples (one test per row): Tandoor's raw Postgres data directory, `tandoor_db_data_dir` (default `/mnt/containers/tandoor-db/pgdata`) (FR-34); the Tandoor `pg_dump` credentials file, at the path the implementation chooses (FR-80)

Scenario AC-31: A failed Tandoor dump fails the backup (FR-36, FR-81; error case: dependency failure)
- Given `tandoor-db.service` is stopped and the operator notes the ID of the latest restic snapshot
- When the operator runs `systemctl start restic-backup.service`
- Then `systemctl is-failed restic-backup.service` prints `failed` (FR-36)
- And a failure email for `restic-backup.service` arrives (FR-36, through the `OnFailure=` hook of A-10)
- And the latest restic snapshot ID is unchanged (FR-81)
- And the operator starts `tandoor-db.service` again afterwards

Scenario AC-32: Cut-over removes Mealie from the host (FR-37, FR-82, BR-07)
- Given a host with `mealie.service` active
- When the operator runs `ansible-playbook site.yml`
- Then `/etc/containers/systemd/mealie.container` does not exist (FR-37)
- And `systemctl cat mealie.service` reports that no such unit exists (FR-37)
- And `podman ps -a --filter name=^mealie$ --format '{{.Names}}'` prints nothing (FR-82)

Scenario AC-33: Mealie removal is idempotent (FR-38)
- Given AC-32 has passed
- When the operator runs `ansible-playbook site.yml` again
- Then every Mealie decommission task reports `ok` or `skipped`, and none reports `changed`

Scenario Outline AC-34: The repository no longer deploys Mealie (FR-39 to FR-42, FR-83 to FR-85, BR-07)
- Given the repository at the feature commit
- When the operator runs `<command>` in `nas-de-int-wahlberger-dev/` (`<vars>` = `inventories/production/group_vars/all/vars.yml`, `<vault dir>` = `inventories/production/group_vars/all`)
- Then the output is `<expected>`
- Examples (one test per row; Mealie mentions in comments are covered by AC-38):

| Requirement | `<command>` | `<expected>` |
|---|---|---|
| FR-39 | `git ls-files roles/mealie` | empty |
| FR-83 | `grep -n -E 'role:\s*mealie\b' site.yml` | empty |
| FR-40 | `grep -n -E '^\s*mealie_' <vars>` | empty |
| FR-84 | `grep -n -E 'upstream:\s*"?mealie:' <vars>` | empty |
| FR-41 | `ansible-vault view <vault dir>/vault.yml \| grep -c vault_mealie_oidc_client_secret` | `0` |
| FR-85 | `grep -c vault_mealie_oidc_client_secret <vault dir>/vault.yml.example` | `0` |
| FR-42 | `grep -n -i mealie roles/homepage/templates/services.yaml.j2` | empty |

Scenario AC-35: Mealie data is kept after the cut-over run (FR-46, BR-01)
- Given the cut-over run has completed and BR-01 is not yet met
- When the operator lists `/mnt/containers/mealie`
- Then the directory exists and still contains Mealie's database file

Scenario AC-36: Mealie data is deleted by hand after BR-01 is met (FR-43, FR-46)
- Given BR-01 is met
- When the owner runs the README step required by FR-60, `rm -rf /mnt/containers/mealie`, as root on the NAS host
- Then `/mnt/containers/mealie` does not exist
- And a following `ansible-playbook site.yml` run does not recreate it

Scenario AC-37: Mealie Pocket ID client is removed (FR-44, BR-09)
- Given BR-01 is met
- When the owner deletes Mealie's client with the README step required by FR-61 and opens the Pocket ID admin UI's OIDC client list
- Then no client has client ID `93041358-e45e-4e44-b838-3c758cfe4681` or the callback URL `https://recipes.de.int.wahlberger.dev/login`
- And the owner can still sign in to Tandoor through Pocket ID

Scenario AC-38: Documentation no longer lists Mealie as deployed (FR-45)
- Given the repository at the feature commit
- When the operator runs `grep -rn -i mealie nas-de-int-wahlberger-dev --exclude=REQS.md`
- Then every match is in the rpi-karlsruhe migration notes, or explicitly describes Mealie as removed or replaced

Scenario AC-39: Idempotent second run (NFR-01)
- Given AC-01 and AC-32 have passed
- When the operator runs `ansible-playbook site.yml` a second time without changing inputs
- Then the play recap shows `changed=0` for the host

Scenario AC-40: Static checks pass (NFR-02)
- Given the repository at the feature commit
- When the operator runs `yamllint .`, `ansible-lint`, and `ansible-playbook site.yml --syntax-check` in `nas-de-int-wahlberger-dev/`
- Then all three exit with status 0

Scenario AC-41: Host reboot (NFR-05; error case: reset)
- Given Tandoor is deployed and the household space contains recipes
- When the operator reboots the NAS host
- Then within 300 s after `systemctl is-system-running` returns `running` or `degraded`, `https://recipes.de.int.wahlberger.dev/` returns 200 or 302 with no manual action
- And the recipes are listed

Scenario AC-42: Documented DB password rotation keeps Tandoor connected (BR-04, FR-57)
- Given Tandoor is deployed
- When the operator follows the README rotation procedure (change the role password inside `tandoor-db`, then update `vault_tandoor_db_password`, then run `site.yml --tags tandoor,restic_backup`)
- Then within 120 s of the run, `tandoor_url` lists the existing recipes
- And the next `systemctl start restic-backup.service` succeeds

Scenario AC-43: Database restart recovers without manual action (NFR-04; error case: dependency restart)
- Given both units are active
- When the operator runs `systemctl restart tandoor-db.service`
- Then within 120 s, `https://recipes.de.int.wahlberger.dev/` returns 200 or 302 and a signed-in user can open a recipe, without a manual restart of `tandoor.service`

Scenario AC-44: Idle memory stays within budget (NFR-06)
- Given `tandoor.service` and `tandoor-db.service` have been active for 10 min with no user activity
- When the operator runs `podman stats --no-stream tandoor tandoor-db`
- Then the sum of the two `MEM USAGE` values is <= 1 GiB

Scenario Outline AC-45: The cut-over run leaves `<command>` output unchanged (NFR-08, NFR-11)
- Given the operator has saved the output of `<command>` on the NAS host before the cut-over run
- When the cut-over run completes and the operator runs `<command>` again
- Then the two outputs are identical
- Examples (one test per row): `ss -tlnH` (NFR-08); `firewall-cmd --list-all` (NFR-11). Mealie published no host port, so removing it changes neither output.

Scenario AC-46: A Pocket ID user outside the allowed groups is refused (BR-08; error case: unauthorised user)
- Given the Tandoor client in Pocket ID has at least one allowed user group, a Pocket ID test user `ac46-test` is in none of them and has no Tandoor account, and the operator notes the Tandoor user count
- When `ac46-test` opens `{tandoor_url}/accounts/login/` and signs in through Pocket ID
- Then Pocket ID shows an error and does not redirect to the Tandoor callback URL with an authorization code
- And the Tandoor user count is unchanged

Scenario AC-47: A failed tandoor run is completed by a re-run (FR-46; error case: cut-over run fails partway)
- Given `tandoor_image` is temporarily set to a tag that does not exist in its registry
- When the operator runs `ansible-playbook site.yml`
- Then the play recap shows `failed=1` for the host
- And `/mnt/containers/mealie` exists if it existed before the run
- And after the operator restores `tandoor_image` and runs `ansible-playbook site.yml` again, the recap shows `failed=0` and `systemctl is-active tandoor.service` prints `active`

Scenario AC-48: The first-user setup page creates no account (FR-21, A-13)
- Given the cut-over run has completed and no Tandoor user exists yet (before the owner's first sign-in)
- When an unauthenticated client opens `{tandoor_url}/setup/` and submits a username and password
- Then no account is created: the Tandoor user count is still 0, per `manage.py shell` in the `tandoor` container

Scenario Outline AC-49: No Tandoor container publishes a host port (FR-49, FR-50)
- Given Tandoor is deployed
- When the operator runs `podman port <container>`
- Then the output is empty
- Examples (one test per row): `tandoor-db` (FR-49), `tandoor` (FR-50)

Scenario AC-50: Argument specs mark the two vars.yml inputs as required (FR-52)
- Given `roles/tandoor/meta/argument_specs.yml`
- When the operator reads the entries for `tandoor_url` and `tandoor_oidc_client_id`
- Then both entries have `required: true`

Scenario AC-51: REST API accepts a token-authenticated read request (FR-77)
- Given AC-26 has passed, so the recipe "AC-26 api" exists, and the operator holds the API token from AC-26
- When a client sends `GET {tandoor_url}/api/recipe/` with header `Authorization: Bearer <token>`
- Then the response status is 200
- And the response body contains "AC-26 api"
- And the same request without the `Authorization` header returns 401 or 403, not a redirect to `https://id.wahlberger.dev`

Scenario AC-52: The feature adds no lint suppression (NFR-09)
- Given the repository at the feature commit
- When the operator runs `git diff master -- nas-de-int-wahlberger-dev ':(exclude)nas-de-int-wahlberger-dev/REQS.md' | grep -E '^\+.*(noqa|skip_list|warn_list)'` from the repository root
- Then the command prints nothing

Scenario AC-53: Backup retention is unchanged (NFR-10)
- Given the repository at the feature commit
- When the operator runs `git diff master -- nas-de-int-wahlberger-dev/roles/restic_backup/defaults/main.yml` and `grep -rn restic_backup_keep_ nas-de-int-wahlberger-dev/inventories` from the repository root
- Then the diff changes no `restic_backup_keep_*` line
- And the `grep` prints nothing, so the role defaults of 7 daily, 4 weekly and 6 monthly snapshots apply

### Non-Functional Requirements

NFR-03 to NFR-06 are owner-confirmed targets (Q5, 2026-09-27), not measurements.

- NFR-01: A second consecutive `ansible-playbook site.yml` run with unchanged inputs reports `changed=0` for the NAS host. This covers the tandoor role, the Mealie decommission tasks, and the tasks this feature changes in `caddy`, `homepage` and `restic_backup`.
- NFR-02: `yamllint .`, `ansible-lint` (production profile per `.ansible-lint`) and `ansible-playbook site.yml --syntax-check` exit 0 in `nas-de-int-wahlberger-dev/`.
- NFR-09: The feature adds no lint suppression. A lint suppression is a `# noqa` comment, or a `skip_list` or `warn_list` entry in `.ansible-lint`.
- NFR-03: On a first-ever deployment (including DB initialisation and migrations), `https://recipes.de.int.wahlberger.dev/` returns HTTP 200 or 302 to a LAN client within 300 s after the play ends.
- NFR-04: In steady state, after `systemctl restart` of `tandoor.service` or `tandoor-db.service`, the same check passes within 120 s.
- NFR-05: After a host reboot, the same check passes within 300 s of `systemctl is-system-running` reporting `running` or `degraded`, with no manual action.
- NFR-06: Measured 10 min after start with no user activity, the combined memory usage of `tandoor` and `tandoor-db` is <= 1 GiB.
- NFR-07: Tandoor data (database content and media files) has a recovery point objective of <= 24 h (nightly 03:00 run).
- NFR-10: Snapshots that contain Tandoor data are kept under the existing, unchanged retention (`restic_backup_keep_daily: 7`, `restic_backup_keep_weekly: 4`, `restic_backup_keep_monthly: 6`).
- NFR-08: The feature adds no host-listening TCP port.
- NFR-11: The feature changes no firewalld rule.

### Verification

| Requirement | Method | Evidence |
|---|---|---|
| FR-01, FR-02 | demonstration | AC-01 (one Then line per FR) |
| FR-62, FR-63 | inspection | AC-01 (one Then line per FR) |
| FR-03, FR-04 | inspection | AC-02 (one Examples row per FR) |
| FR-49, FR-50 | inspection | AC-49 (one Examples row per FR) |
| FR-05, FR-64, FR-65, FR-06, FR-66 | inspection | AC-03 (one Examples row per FR) |
| FR-07, FR-67 | demonstration, inspection | AC-04 (one Examples row per FR) |
| FR-08, FR-51 | inspection | AC-05 (one Examples row per FR) |
| FR-09 | inspection | AC-06 |
| FR-10, FR-68 | inspection | AC-07 (one Examples row per FR) |
| FR-11 | demonstration | AC-09 |
| FR-69 | demonstration | AC-08 |
| FR-12, FR-70, FR-71 | test | AC-10 (5 examples; one Then line per FR) |
| FR-13 | inspection | AC-11 |
| FR-52 | inspection | AC-50 |
| FR-14, FR-72, FR-53, FR-73, FR-74, FR-54 to FR-56, FR-58, FR-59, FR-75, FR-60, FR-61 | inspection | AC-12 (one Examples row per FR) |
| FR-57 | inspection, demonstration | AC-12 (FR-57 row), AC-42 |
| FR-15 | inspection | AC-13 |
| FR-16, FR-17 | demonstration | AC-14, AC-21 |
| FR-18 | inspection | AC-15 |
| FR-19 | demonstration | AC-14, AC-19 |
| FR-20 | demonstration | AC-16 |
| FR-21 | demonstration | AC-17, AC-48 |
| FR-22 | demonstration | AC-19 |
| FR-23 | test | AC-22 |
| FR-24 | demonstration | AC-23 |
| FR-25, FR-26 | demonstration | AC-24, AC-25 |
| FR-27 | test | AC-26 |
| FR-77 | test | AC-51 |
| FR-28 to FR-31, FR-78 | inspection | AC-27 (one Then line per FR) |
| FR-32, FR-79 | inspection | AC-28 (one Then line per FR) |
| FR-33, FR-35 | demonstration | AC-29 |
| FR-34, FR-80 | inspection | AC-30 (one Examples row per FR) |
| FR-36, FR-81 | demonstration | AC-31 (one Then line per FR) |
| FR-37, FR-82 | demonstration | AC-32 (one Then line per FR) |
| FR-38 | demonstration | AC-33 |
| FR-39 to FR-42, FR-83 to FR-85 | inspection | AC-34 (one Examples row per FR; FR-42 also AC-24) |
| FR-43 | inspection | AC-36 |
| FR-44 | inspection | AC-37 |
| FR-45 | inspection | AC-38 |
| FR-46 | inspection | AC-35, AC-36, AC-47 |
| FR-47, FR-76 | inspection | AC-14, AC-19 (one Then line per FR) |
| FR-48 | demonstration | AC-18 |
| BR-01 | inspection | AC-35, AC-36 |
| BR-02 | inspection | AC-27 |
| BR-03 | inspection | AC-22 |
| BR-04 | demonstration | AC-42 |
| BR-05 | inspection | AC-12 (FR-58 row) |
| BR-06 | inspection | AC-24 |
| BR-07 | inspection | AC-22, AC-32, AC-34 |
| BR-08 | demonstration | AC-46, AC-19 |
| BR-09 | inspection | AC-27, AC-37 |
| Error case: cut-over run fails partway | demonstration | AC-47 |
| NFR-01 | demonstration | AC-39 |
| NFR-02 | test | AC-40 (CI + local) |
| NFR-09 | inspection | AC-52 |
| NFR-03 | demonstration | AC-01 |
| NFR-04 | demonstration | AC-43, AC-25 |
| NFR-05 | demonstration | AC-41 |
| NFR-06 | analysis | AC-44 |
| NFR-07 | demonstration | AC-29 |
| NFR-10 | inspection | AC-53 |
| NFR-08 | inspection | AC-45 (NFR-08 row) |
| NFR-11 | inspection | AC-45 (NFR-11 row) |

### Out of Scope

- Automated migration of the 2 Mealie recipes: not needed; the owner re-enters them by hand (approved by the owner).
- The photo-to-recipe import workflow (photo -> parse -> `POST /api/recipe/`): deferred to a future feature. This feature only proves token-authenticated API writes work (FR-27).
- Automated rotation of `vault_tandoor_db_password` or `vault_tandoor_secret_key`: only documented (BR-04, BR-05).
- SMTP/email configuration for Tandoor (invites, password reset): not needed, because sign-in is OIDC-only and users join the household space automatically (FR-22); the A-12 fallback uses a copied invite link, not email.
- Group- or email-based access control inside Tandoor: not needed; the Tandoor client's allowed user groups in Pocket ID decide who signs in (BR-08, Q1).
- DNS and TLS certificate changes: none needed; Tandoor reuses `recipes.de.int.wahlberger.dev`, whose Cloudflare CNAME and Caddy certificate already exist (Q2).
- Tandoor in-app configuration beyond creating the household space (units, foods, keywords, meal plans, shopping lists, external storage sync): the owner does this in the UI.
- Molecule coverage for the tandoor role: excluded, like every Podman-backed role (see `molecule/default/converge.yml`).
- A restore drill of the Tandoor SQL dump: this gap already exists for paperless and immich; deferred to a separate backup-verification feature.
- Retiring rpi-karlsruhe's `mealie` role: separate host, done in `rpi-karlsruhe/main.yml` (per CLAUDE.md "Continuity with rpi-karlsruhe").
- Removing the Mealie container image: the existing `podman-image-prune.timer` deletes it (A-09).
- Changes to the Pocket ID deployment on cloud-wahlberger-dev: only registering the Tandoor client, setting its allowed user groups, and deleting Mealie's client in the Pocket ID admin UI.
- Won't: running Mealie and Tandoor side by side on separate hostnames (Q2 option B rejected by the owner; BR-07).
- Won't: an Ansible task that deletes `/mnt/containers/mealie`; deletion is a manual README step (Q3, FR-43, FR-46).
- Won't: reusing Mealie's Pocket ID client for Tandoor (Q4, BR-09).
- Won't: a shared multi-database Postgres role (C-02, per-service pattern).

### Open Questions

None.

Decision log (answered by the owner on 2026-09-27, kept for traceability):
- Q1 (sign-in and provisioning): every Pocket ID user the Tandoor client admits gets an automatically created non-admin account; the owner creates the household space and is its admin; access is restricted only through the client's allowed user groups in Pocket ID. -> FR-19, FR-22, FR-47, FR-76, FR-48, BR-08.
- Q2 (hostname and sequence): option A, one-shot cut-over at `recipes.de.int.wahlberger.dev`; `/mnt/containers/mealie` stays as the rollback path until BR-01 is met. -> BR-07, primary flow, `tandoor_url`.
- Q3 (Mealie data deletion): manual `rm -rf` documented in `roles/tandoor/README.md`; Ansible removes only the Mealie unit and container. -> FR-43, FR-46, FR-60.
- Q4 (Pocket ID client): a new client for Tandoor; Mealie's client is not reused and is deleted after BR-01 is met. -> BR-09, FR-44, FR-53, FR-61.
- Q5 (NFR numbers): 300 s first deploy, 120 s restart, 300 s after reboot, 1 GiB combined memory confirmed. -> NFR-03 to NFR-06; A-07 withdrawn.
