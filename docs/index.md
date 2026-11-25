# Architecture decisions and plans

Dated records. Each one states its status at the top. Superseded parts are marked in the file.

- [AI-assisted incident pipeline (Uptime Kuma -> n8n -> GitHub -> Semaphore)](ai-incident-remediation-pipeline.md): 2026-09-27, proposed; amended 2026-11-24. Read-only triage first; bounded autonomy for Renovate PRs and a scheduled deploy.
- [Phase 3 write-remediation plan](ai-remediation-phase3-plan.md): 2026-11-24, approved in part. Preconditions, kill switch and rollout for the pipeline above.
- [n8n triage workflow (phase 2, read-only)](n8n-triage-workflow.md): 2026-11-24, proposed. Hush handoff, prompt template and allowlists.
- [n8n + Claude gate for Renovate PRs](renovate-merge-gate.md): 2026-11-23, proposed; amended 2026-11-24. Deterministic classifier decides; the merge is pinned to the reviewed SHA.
- [Semaphore to Gotify request capture](semaphore-gotify-capture.md): 2026-11-24, observation. Request shape captured from Semaphore's test alert; the failure text is not yet captured.
