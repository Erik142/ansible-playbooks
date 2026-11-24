## Decision: n8n + Claude gate for Renovate PRs          date: 2026-11-23   status: proposed

### Context
- Renovate opens dependency PRs on `master` (`renovate.json`). Minor/patch container bumps are automerged once CI passes. Majors, Forgejo, Pocket ID, Caddy and Postgres majors are excluded or manual.
- Erik's scope for the gate: container bumps **and** role/collection bumps (e.g. `geerlingguy.security` in `requirements.yml`, `ansible.cfg` tooling), not majors on the excluded list.
- Done 2026-11-23: branch protection on `master`. Required checks are the 18 CI contexts (`discover`, `validate (<dir>)`, `molecule (<dir>)`, `vault-encrypted`, `ops-static`, `nas-backup-static`). 0 required approvals, `enforce_admins: false`, no force-push, no deletion. Merging is still possible without a human once checks are green.
- Merge does **not** apply anything. Semaphore runs by schedule (`ops-de-wahlberger-dev/README.md`, SH-BR-07 window 03:00-05:30), not on push. So a merge only changes the desired state; an application happens at the next scheduled run. Verify that rule before relying on it.
- `allow_auto_merge` is `false` at repo level. Renovate's automerge therefore merges directly once checks pass, which is what protection allows with 0 approvals. Re-check after protection went on.
- Renovate PR bodies include upstream release notes. That text is untrusted input to the LLM.

### Options considered
1. **Verdict only** (Claude comments, Erik merges). Lowest risk, no value gained over reading the PR.
2. **Gate merges green PRs that pass deterministic checks and an LLM verdict; LLM may push one fix commit, then re-check.** Chosen.
3. **Gate without deterministic checks** (LLM alone decides). Rejected: the LLM is the least reliable part, and it reads attacker-influenced text.

### Chosen approach
Deterministic classifier first, LLM second, merge last. The LLM never holds the merge decision alone.

1. **Select.** n8n polls open PRs from `app/renovate` every 15 min. Skip a PR whose head SHA has already been decided (state in n8n).
2. **Classify (no LLM).** Read the changed file list and diff size.
   - Allowlist (may change): `roles/*/defaults/main.yml` (versions and image tags), `roles/*/templates/**`, `requirements.yml`, `renovate.json` not included, role `meta` untouched.
   - Denylist (any hit = human only): `**/vault.yml`, `.github/**`, `**/ssh_authorized_keys/**`, `roles/security/**`, `roles/firewall/**`, `roles/caddy/**`, `roles/zerotier/**`, `roles/podman/**`, `pi-*/**`, `ops-*/roles/semaphore/**`, `*.yml` under `tests/` and `molecule/`, and the Ansible `ansible.cfg`.
   - Diff budget: at most 60 changed lines and 6 files for an automerge candidate.
   - Major update types, or anything `renovate.json` excludes: human only.
   - Fails the classifier: post a comment with the reason and stop. No LLM call.
3. **Review (Claude, structured output).** Input: the diff, the Renovate release-notes section, the CI log summary, and the role's README. Output is a JSON schema only: `verdict` (`safe` | `fixable` | `unsafe`), `reasons[]`, and for `fixable` a `patch` limited to allowlisted paths. Free text is never executed.
4. **Fix (only if `fixable`).** Apply the patch as one commit on the Renovate branch with the GitHub App identity. This stops further Renovate updates on that branch, which is the intended behaviour. Wait for CI to finish, then go back to step 1 with the new SHA. Maximum **one** fix iteration per PR.
5. **Merge (only if all hold).** Head SHA is the SHA that was classified and reviewed. CI is green on that SHA. Classifier passes on that SHA. Verdict is `safe`. Merge with the API's `sha` parameter, so a SHA that changed in between fails the merge. Squash merge.
6. **Otherwise.** Leave the PR open, comment the verdict and reasons, and send a hush event (`kind: alert`, source `n8n`) so Erik gets an e-mail. Fail closed on any error.

### Contract / ownership
- **GitHub App** on this one repo, not a PAT. Permissions: Contents write, Pull requests write, Checks read. **No Workflows permission**, so it cannot change `.github/workflows`. The denylist also blocks it.
- Claude only proposes patches. Commits and merges happen in deterministic n8n nodes, with the App's token.
- Claude never sees `vault.yml` or any secret. Its input is the diff and public release notes only.
- Kill switch: an n8n workflow toggle, plus `renovate.json` `"enabled": false` as a fallback.
- Cost cap per PR and per day in the n8n workflow. Same pattern as hush `daily_budget_usd`.
- Every decision (verdict, SHA, classifier result, merge result) is written to the PR as a comment and to n8n's execution log.

### Prompt injection
- Release notes and PR text can contain instructions. Mitigations, in order of strength:
  1. The classifier is code, not prompt, and decides what may change.
  2. The LLM output is schema-validated. A `patch` touching a non-allowlisted path is rejected.
  3. The LLM has no tools. It cannot push, merge or run commands.
- Accepted residual risk: a malicious release could ship an upgrade the LLM calls `safe`. It would then have to pass CI and stay within the allowlist. The denylist keeps the blast radius at role defaults and templates.

### Rollout
1. Protection on master: done (2026-11-23).
2. n8n deployed on NAS (PLAN-n8n.md phase 1).
3. **Dry run for 2-3 weeks:** full pipeline, but step 5 posts "would merge" and does not merge. Compare verdicts with what Erik would have decided.
4. Enable merge for container bumps first, then role/collection bumps once the dry-run mismatch rate is low.

### Consequences / open items
- A merged role bump runs at the next Semaphore schedule. Check which template schedules run `common` (`common_upgrade: true` triggers a full zypper/apt upgrade). A scoped template is the ADR's prerequisite. Not yet in place.
- Pi directory is excluded from Renovate; keep it so.
- The NAS-hosted n8n holds the App private key and the Anthropic key. Same host-choice reasoning as `PLAN-n8n.md` §1.
- Dependency on hush: if n8n is down, Renovate PRs wait. Nothing is merged while the gate is down. Fail closed.
