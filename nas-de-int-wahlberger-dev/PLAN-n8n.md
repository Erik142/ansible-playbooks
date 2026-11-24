# PLAN: n8n on nas.de.int.wahlberger.dev

Status: draft, 2026-10-31. Implements phases 1-2 of
[`architecture/ai-incident-remediation-pipeline.md`](../architecture/ai-incident-remediation-pipeline.md).
Hush-side contract: `hush` repo, "remediation handoff" requirements (pending review).

## 1. Host decision

| Host | Verdict | Why |
|---|---|---|
| **NAS** (`nas.de.int`) | **Use for phases 1-2 (read-only triage).** | Already runs the Quadlet + Caddy + Pocket ID pattern. Reachable from ops (hush) over ZeroTier with no port forward. Holds the restic/snapper data, which is the only thing n8n must not be able to touch, and it does not. |
| ops (`ops.de.wahlberger.dev`) | **Reject.** | Holds Semaphore, the sole automation key with passwordless sudo on all hosts. An n8n compromise through its LLM-driven workflow nodes would reach Semaphore's API, which runs playbooks as root everywhere. Also public. |
| cloud | **Reject.** | Public Hetzner VM. Holds Pocket ID and Kuma. Putting credentials that reach the home LAN there is the wrong direction. |
| pi (`pi.de.int`) | **Reject.** | Holds the infra master keys and the vault password. |
| Dedicated small VM (new) | **Revisit before phase 3.** | Phase 3 needs a GitHub write token and SSH to every host. That is more than the NAS should hold next to household data and Immich/Paperless load. Cost: one more host, one more ZeroTier member needing manual authorization. |

Shared-fate accepted for phases 1-2: when the NAS is down, n8n is down and hush's
fail-open rule e-mails Erik directly. That is the intended behaviour.

Conflict to acknowledge: the ADR's v1 is read-only and says "do not adopt n8n just for
this". Phase 3 (draft PRs, merge, Semaphore apply) is the ADR's option 3 at the
earliest, and its guardrails are a precondition. This plan does not authorise phase 3.

## 2. Role `nas-de-int-wahlberger-dev/roles/n8n`

Follows the `forgejo` role layout: rootful Podman Quadlet, joins `caddy.network`,
reverse-proxied by `caddy` at `n8n.de.int.wahlberger.dev`, LAN/ZeroTier only.

- **Image**: `docker.io/n8nio/n8n:<pinned>`. Stable line as of 2026-11-23 is 2.47.x
  (changelog: stable 2.47.4, beta 2.48.1; the docs' install page still showed 2.46.4, so
  re-check at deploy time). Pin the exact tag in defaults, do not use `latest`. Renovate
  proposes minor/patch bumps; major stays manual.
- **Data**: `/mnt/containers/n8n` (restic- and snapper-covered like the other containers).
- **Database**: n8n's default SQLite is enough for this load. Check whether `roles/db_dump`
  should cover it. Decision needed.
- **Secrets** (vault, root-only env file, not in the Quadlet unit, same as forgejo):
  - `vault_n8n_encryption_key`: **critical**. Encrypts all n8n credentials. Losing it
    loses every stored credential. Back it up in 1Password as well as in the vault.
  - `vault_n8n_owner_password`
  - `vault_n8n_hush_secret`: HMAC secret for hush -> n8n (matches hush `webhook` secret file)
  - `vault_n8n_diag_ssh_key`: dedicated key, `restrict,command=…/diag-bundle` on each host
  - `vault_n8n_github_token`: read-only fine-grained token for phase 2
  - `vault_n8n_anthropic_key`: separate from hush's key, so spend is separable
- **Access**: no public inbound port. Caddy vhost on the LAN/ZeroTier side only.
- **Hardening**:
  - `NODES_EXCLUDE='["n8n-nodes-base.executeCommand"]'` (documented; verified).
  - `N8N_RESTRICT_FILE_ACCESS_TO` set to the data dir, but verify on 2.47: community reports
    say subdirectory handling is fiddly.
  - `N8N_BLOCK_FILE_ACCESS_TO_N8N_FILES=true` (default, verify).
  - Diagnostics/telemetry off: no official doc entry found for `N8N_DIAGNOSTICS_ENABLED`.
    Verify on the running version before relying on it.
  - `N8N_PUBLIC_API_DISABLED`: the docs description appears to contradict its name. Verify
    behaviour before setting it. Do not assume.
- **Resources**: NAS has 23 GiB RAM and 4 cores (read live 2026-11-23, 4.4 GiB used, 18 GiB
  available). Cap n8n with `MemoryMax=2G` as a starting point, `CPUQuota=200%`.

### Auth
- Verified 2026-11-23: n8n community edition has no SSO. OIDC is Enterprise only; SAML is
  Business and up ([n8n community edition features](https://docs.n8n.io/hosting/community-edition-features),
  [n8n OIDC docs](https://docs.n8n.io/user-management/oidc)). Community-hook SSO workarounds
  exist but are unverified against licensing, so do not rely on them.
- Use `oauth2-proxy` + Pocket ID in front of the editor, the same pattern as
  `cloud-wahlberger-dev/roles/uptime_kuma`.
- Webhook path (`/webhook/hush` only) bypasses the proxy. It is authenticated by the HMAC
  header check in the first workflow node, not by Pocket ID.

## 3. Interfaces

| From -> to | Path | Auth | Notes |
|---|---|---|---|
| hush (ops) -> n8n (NAS) | `POST https://n8n.de.int.wahlberger.dev/webhook/hush` over ZeroTier | HMAC, `X-Hush-Signature` | Payload per hush requirements |
| n8n -> hush | `POST https://hush.de.int.wahlberger.dev/ingest/remediation` | HMAC, separate secret | Caddy on ops limits `/ingest/*` to LAN, ZeroTier, cloud |
| n8n -> each host | SSH `diag-bundle` (forced command) | dedicated key | Argument: unit name from allowlist |
| n8n -> GitHub | read commits, Renovate merges | read-only token | Phase 2 |
| n8n -> Semaphore | read last task result | Guest role (read-only) | Semaphore's built-in Guest role is read-only and task logs are visible to it ([team roles](https://docs.semaphoreui.com/user-guide/team)). See the caveat in §5 about a GET-permission CVE. |

Forced-command `diag-bundle` is a separate role change on each playbook host (see ADR).
It is a prerequisite for phase 2, not part of this role.

## 4. Phases

### Phase 0: prerequisites (before any n8n)
- Protect `master` on GitHub: require PR and green CI, no direct push. The ADR found no
  rulesets; verify again.
- Hush outbound contract merged and deployed (hush repo, after review).
- Caddy route for `/ingest/remediation` on ops, network-limited.

### Phase 1: n8n role on NAS, no workflows
- Role, vault entries, Caddy vhost, backup coverage, Quadlet, healthcheck.
- Verify: UI reachable over ZeroTier, not from WAN. Webhook returns 401 without a valid
  signature. Container restarts clean. Restic backup includes `/mnt/containers/n8n`, and the
  encryption key restores into a fresh instance.
- Owner login works, credentials survive a restart.

### Phase 2: read-only triage (ADR option 2)
- Workflow: verify signature, collect diag bundles, recent GitHub commits, last Semaphore
  task, call Claude (`claude-haiku-5-5`, same as hush) with a fixed template and redacted
  input.
- Output: always `outcome: escalate` with the triage report. n8n never returns `resolved`
  in this phase. Hush e-mails Erik with the report.
- Success criterion: over two to four weeks, triage reports match root causes you found by
  hand. Only then consider phase 3.

### Phase 3: write remediation (ADR option 3, separate decision)
- Not planned in detail yet. Preconditions: branch protection on, GitHub App with no
  Workflows permission, ruleset for `ai/*` branches and draft PRs, CI path guard for
  `vault.yml`, `.github/`, `ssh_authorized_keys`, `security`, `firewall`, scoped
  `--tags` Semaphore template with `common_upgrade=false`, and the host decision in §1
  revisited.

## 5. Verified and open items

Verified 2026-11-23:
- NAS: 23 GiB RAM, 4 cores (live read).
- n8n: no SSO on community edition; use oauth2-proxy (§2).
- Semaphore: Guest role is read-only and sees task logs (docs, not yet tested on ops).
- Renovate: a human push to a `renovate/*` branch stops Renovate updating that branch
  ([updating & rebasing](https://docs.renovatebot.com/updating-rebasing/)). Fix commits
  therefore do not get overwritten, but the PR then has to be merged by hand or by the gate.

Open:
- **Semaphore CVE**: an advisory says Semaphore through 2.19.12 exempts GET/HEAD from
  project permission checks, so Guest and Task Runner can read environment secrets
  ([osv CVE-2026-91994](https://osv.dev/vulnerability/CVE-2026-91994)). ops pins
  `semaphore:v2.19.17`. Confirm the fix version and that 2.19.17 contains it. If unsure,
  upgrade first, before wiring n8n to Semaphore.
- n8n's `N8N_DIAGNOSTICS_ENABLED` and `N8N_PUBLIC_API_DISABLED` semantics (§2).
- Whether hush should send hostnames unredacted to n8n (decision for Erik, in the hush review).
