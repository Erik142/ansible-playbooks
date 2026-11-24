# PLAN: n8n on nas.de.int.wahlberger.dev

Status (2026-11-24): **phase 1 done** (editor, one login via Pocket ID + trusted-header hook, owner created, backups). **Phase 2 not started.**
Implements phases 1-2 of [`architecture/ai-incident-remediation-pipeline.md`](../architecture/ai-incident-remediation-pipeline.md).
Hush-side contract: `hush` repo, "remediation handoff" requirements (HUSH-NOTIFY-040 to -048, HUSH-INGEST-036 to -042).

## 1. Host decision (unchanged)

| Host | Verdict | Why |
|---|---|---|
| **NAS** | **Used for phases 1-2 (read-only triage).** | Already runs the Quadlet + Caddy + Pocket ID pattern. Reachable from ops (hush) over ZeroTier with no port forward. Holds the restic/snapper data, which n8n must not touch. |
| ops | Rejected | Holds Semaphore and the sole automation key with passwordless sudo on all hosts. |
| cloud | Rejected | Public VM. Holds Pocket ID and Kuma. |
| pi | Rejected | Holds the infra master keys and the vault password. |
| Dedicated small VM | Revisit before phase 3 | Phase 3 needs a GitHub write token and SSH to every host. |

Shared fate accepted for phases 1-2: when the NAS is down, n8n is down and hush's fail-open rule e-mails Erik directly.

Phase 3 (write remediation) is not authorised by this plan (ADR option 3 at the earliest).

## 2. Role `nas-de-int-wahlberger-dev/roles/n8n` (as deployed)

- **Image:** `docker.io/n8nio/n8n:2.48.8`, pinned. The stable channel per docs.n8n.io/changelog on 2026-11-24. v3.0 is early access in the n8n docs and v3.3.0 is a GitHub prerelease, so v3 is out of scope until stable. Renovate proposes v3 as a major, which stays manual (closed #73, 2026-11-24).
- **Data:** `/mnt/containers/n8n/data` (uid 1000). btrbk and snapper cover it. **db_dump** dumps `database.sqlite` into `/mnt/containers/db-dumps` (WAL-safe, see the db_dump role).
- **Secrets (vault):** `vault_n8n_encryption_key` (back up in 1Password; losing it loses every credential), `vault_n8n_oidc_client_secret`, `vault_n8n_oauth2_cookie_secret`. No owner password: the owner is created in the first-run UI behind Pocket ID.
- **Login (one, not two):** oauth2-proxy admits only `n8n_allowed_emails` (erik@wahlberger.dev). Caddy strips a client-sent `X-Auth-Request-Email` and copies the value from the oauth2 response. `files/hooks.js` (EXTERNAL_HOOK_FILES) issues n8n's session cookie for the user with that email. The hook is our own: the header check in the public write-up is absent from n8n 2.x. Its test is CI job `n8n-hook` (`tests/n8n-hook/run.sh`), a required check on `master`.
- **Hardening:** `NODES_EXCLUDE` blocks `executeCommand`. Telemetry off via env. Resources `MemoryMax=2G`, `CPUQuota=200%`. No published port: Caddy is the only ingress.
- **Access:** LAN/ZeroTier only. `/webhook/hush` bypasses Pocket ID (for phase 2) and must be HMAC-checked by the workflow.

## 3. Interfaces

| From -> to | Path | Auth | Status |
|---|---|---|---|
| hush (ops) -> n8n | `POST https://n8n.de.int.wahlberger.dev/webhook/hush` | HMAC, `X-Hush-Signature` | phase 2 |
| n8n -> hush | `POST https://hush.de.int.wahlberger.dev/ingest/remediation` | HMAC, separate `remediation.secret` | phase 2 |
| n8n -> each host | SSH `diag-bundle` (forced command) | dedicated key | phase 2 |
| n8n -> GitHub | read commits, Renovate PRs | read-only token | phase 2 |
| n8n -> Semaphore | read last task result | Guest role | phase 2, after the CVE check (§5) |

Hush sends host, service and check names unredacted in the handoff (OPEN-REM-01, resolved 2026-10-31). Hostnames must be redacted before any Claude call inside n8n (decided 2026-11-24).

## 4. Phases

### Phase 1: editor, backups, one login (done)
- Role, vault entries, Caddy vhost, backup coverage (btrbk/snapper + db_dump), Quadlet, healthcheck, trusted-header hook. Deployed 2026-11-24.
- Verified 2026-11-24: owner exists (erik@wahlberger.dev); Pocket ID login opens the editor without a second login; a spoofed header without a session gets a redirect to sign-in (302) on the editor and on API routes.
- Not verified: an oauth2 session plus a spoofed header (Caddy overwrite while a real session exists). Accepted risk: n8n is LAN/ZeroTier only, so the risk is low (decided 2026-11-24).
- Not verified: restoring the encryption key into a fresh instance. Do this before phase 2 holds real credentials.

### Phase 2: read-only triage (ADR option 2) (next)
- Workflow: verify the signature, collect diag bundles, recent GitHub commits, last Semaphore task, call Claude (`claude-haiku-5-5`) with a fixed template and redacted input. Hostnames are redacted before the Claude call.
- Output: always `outcome: escalate` with the triage report. n8n never returns `resolved` in this phase. Hush e-mails Erik the report.
- Needs: Hush HMAC secret, remediation reply secret, diag SSH key (restricted command on each host), GitHub read-only token, Anthropic key (separate from hush's, so spend is separable). Hush-side forced-command role is a prerequisite.
- Success criterion: over two to four weeks, triage reports match root causes found by hand. Only then consider phase 3.

### Phase 3: write remediation (separate decision)
Not planned. Preconditions: branch protection (done for the n8n-hook check), GitHub App without Workflows permission, ruleset for `ai/*` branches and draft PRs, CI path guard for `vault.yml`, `.github/`, `ssh_authorized_keys`, `security`, `firewall`, scoped `--tags` Semaphore template with `common_upgrade=false`, and the host decision in §1 revisited.

## 5. Verified and open items

Verified (dated):
- NAS: 23 GiB RAM, 4 cores, ~18 GiB free (2026-11-23).
- n8n: no SSO on community edition (OIDC/SAML are licensed). Verified against docs (2026-11-23).
- n8n 2.48.8 image: no `N8N_FORWARD_AUTH_HEADER` or trusted-header support. External hooks, the cookie-parser layer, `issueCookie` and the `n8n-auth` cookie are present. The hook works against it (2026-11-24).
- The n8n stable channel is 2.48.8 (2026-11-23). My earlier pin of 2.47.4 was stale.
- Pocket ID OIDC login through oauth2-proxy opens the editor (2026-11-24).

Open:
- **Semaphore CVE:** Semaphore through 2.19.12 exempts GET/HEAD from project permission checks, so Guest and Task Runner can read environment secrets ([osv CVE-2026-91994](https://osv.dev/vulnerability/CVE-2026-91994)). Confirm the fixed version before wiring n8n to Semaphore (phase 2).
- `N8N_PUBLIC_API_DISABLED`: not set. The documented meaning contradicts its name. Verify on 2.48.8 before setting it.
- `N8N_RESTRICT_FILE_ACCESS_TO=/home/node/.n8n`: subdirectory handling is reported as fiddly. Verify on 2.48.8.
- `N8N_DIAGNOSTICS_ENABLED=false`: documented in the isolation guide. Verify the effect on a running instance.
- Caddy overwrite of a spoofed header while a session exists (see §4, phase 1).
- Encryption-key restore into a fresh instance (see §4, phase 1).
- Phase 2 webhook: `/webhook/hush` is not yet an endpoint. Its 401 check comes with the workflow.
