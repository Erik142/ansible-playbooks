# Plan: phase 3, write remediation (proposed, 2026-11-24)

Status: proposal, not approved. Builds on [`ai-incident-remediation-pipeline.md`](ai-incident-remediation-pipeline.md) (ADR, option 3) and [`renovate-merge-gate.md`](renovate-merge-gate.md). Nothing in this plan starts before phase 2a's shadow period has produced results and Erik has approved the preconditions below.

## 1. What phase 3 is, and what it is not
Phase 3 lets n8n change the repository, never the hosts. Two capabilities only:

| Capability | Allowed in phase 3 | Notes |
|---|---|---|
| Merge a Renovate PR | Yes, via the merge gate | Deterministic classifier, Claude reviews, merge pinned to the reviewed SHA (renovate-merge-gate.md) |
| Open a draft PR for an incident | Yes, narrow class only | Example: revert a Renovate bump merged shortly before an alert. A human merges it. |
| Run Ansible, or change a host | No | Semaphore runs on schedule. n8n has no route to a playbook run, and it never gets the automation key. |
| SSH into a host to change it | No | The `n8n-diag` key stays read-only. |
| Restart a unit or fix a host by hand | No | Hosts change only through reviewed playbooks. |

Merges don't apply anything. A merged fix reaches a host at the next scheduled Semaphore run. So phase 3 can shorten the review step, not the time to a fix. That limit comes from the ADR and should be stated in every alert.

## 2. Preconditions (all must hold before the first real merge)
From `PLAN-n8n.md` §4 phase 3, plus the merge gate:
1. Branch protection on `master` with the required checks, including `n8n-hook` (done 2026-11-24 for `n8n-hook`; the other checks are in place from 2026-11-23).
2. A GitHub App for this repository, not a personal token. Permissions: contents write, pull requests write, checks read. **No Workflows permission.**
3. A ruleset for `ai/*` branches and draft PRs. The App cannot push to `master`.
4. A CI path guard that fails any change to `vault.yml`, `.github/`, `ssh_authorized_keys`, `security`, `firewall` on an App-authored PR, independent of the classifier.
5. A scoped Semaphore template with `common_upgrade=false`, so a merged role bump does not trigger a full `zypper`/`apt` upgrade. The ADR's prerequisite; not yet in place.
6. Host decision revisited. The App private key and the Anthropic key would sit on the NAS. `PLAN-n8n.md` §1 already flags a dedicated small VM for phase 3. Erik decides before step 4 of the rollout.
7. The phase 2a shadow results reviewed, with the mismatch rate between `PROPOSED_ACTION` and the human decision recorded.

## 3. Components and their limits
- **Monitor PRs:** the App token lists open PRs and reads CI results. Nothing else.
- **Classify:** deterministic code, no LLM. Allowlist, denylist and diff budget are in `renovate-merge-gate.md`.
- **Review:** Claude with structured output only. No tools. Schema-validated, and any patch outside the allowlist is rejected.
- **Patch and commit:** one commit on the Renovate branch by the App. The commit stops further Renovate updates on that branch, as intended.
- **Merge:** the API's `sha` parameter, so a SHA that moved fails the merge. Only after classifier, verdict and CI all pass on that SHA.
- **Draft PR for an incident:** same App, `ai/` branch, draft only. The PR body states the incident, the evidence and the reverse change. A human merges it.
- **Notify:** every outcome goes to the PR as a comment and to a hush `alert` handoff (e-mail). Each message states what was done, what was not done, and why.
- **Audit:** the execution record (30 days, as in phase 2a) plus the PR comments. The PR history is kept in git.

## 4. Kill switch and limits
- Toggle the n8n workflow off. Fallback: `"enabled": false` in `renovate.json`.
- A per-PR and per-day cost cap, as for hush's daily budget.
- Any error fails closed: no merge, a comment, and an alert.

## 5. Rollout and gates
1. **Dry run, 2–3 weeks.** The whole pipeline runs, but the merge step only posts "would merge". Compare every decision with what Erik would have done. Gate: the mismatch rate is low and no decision was unsafe.
2. **Container bumps only.** Enable the merge for minor and patch container bumps. Gate: no regressions in two weeks.
3. **Role and collection bumps.** Enable after the scoped Semaphore template (precondition 5) is in place.
4. **Incident drafts.** Only after 1–3, and only for the narrow class in §1.

## 6. Risks and accepted residuals
- A malicious or wrong release note could make the review call an upgrade `safe`. The change would still need green CI and must stay in the allowlist. Accepted: the blast radius is role defaults and templates.
- A merged change waits for the next scheduled run. An alert can't promise a fix time.
- The App key on the NAS: if the NAS is compromised, so is the App. That is why precondition 6 exists.

## 7. Decisions for Erik
1. Host for phase 3: the NAS, or a dedicated VM.
2. Which classes may merge at all: container bumps only, or role and collection bumps too.
3. Whether incident drafts are wanted at all, given the 2–3 week dry-run results.
4. Who gets alerts for denied or failed merges: e-mail only, or also a hush alert with a higher priority.
