# Architecture decisions

- [AI-assisted incident pipeline (Uptime Kuma -> n8n -> GitHub -> Semaphore)](ai-incident-remediation-pipeline.md): 2026-09-27, proposed. v1 read-only AI triage only; no autonomous fix PRs or merge-triggered apply.
- [n8n + Claude gate for Renovate PRs](renovate-merge-gate.md): 2026-11-23, proposed. Deterministic classifier decides; Claude proposes one allowlisted fix commit; merge pinned to the reviewed SHA. Dry run first.
