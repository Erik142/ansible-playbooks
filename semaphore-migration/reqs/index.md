# Requirements — semaphore-migration

Cross-playbook features that touch `pi-de-int-wahlberger-dev`, `nas-de-int-wahlberger-dev`, `cloud-wahlberger-dev` and the new Hetzner VM playbook `ops-de-wahlberger-dev`. One line per file. Read this file first to know what exists. The implementation plan is `semaphore-migration/PLAN.md`.

| File | Feature | Status | Version | Scope | Quality |
|---|---|---|---|---|---|
| [semaphore-to-hetzner.md](semaphore-to-hetzner.md) | Move Semaphore from the Pi to a Hetzner VM (UI over ZeroTier only, key-only public SSH) and retire the Pi | ready | 1.3 | New Tumbleweed CX23 playbook `ops-de-wahlberger-dev`; key-only public SSH with hardening and a bounded bootstrap window (accepted risk SH-R-01); UI on ZeroTier only (host-networked Caddy bound to the ZT IP, `remote_ip` allowlist, bridge fallback selected by `vm_proxy_design`); ZeroTier Central flow rules; DNS `ops.de.wahlberger.dev` / `ops.de.int.wahlberger.dev`; Semaphore DB migration checked against the live Pi; automation key rotation; backups to the NAS rest-server; self-run rules; pull-request plan (A, A2, A3, B, B2, C, C2, C-R, D, E) safe under "merge is deploy"; Renovate freeze; runbook with per-step gates and rollbacks; Pi retirement with a point of no return; documentation | not scored (assumptions SH-A-19 to SH-A-34 verified at named steps) |

## ID map

All IDs in this directory carry the prefix `SH-`. "[Deleted]" IDs are kept and never reused.

| File | IDs |
|---|---|
| semaphore-to-hetzner.md | SH-C-01 to SH-C-05, SH-D-01 to SH-D-22, SH-FR-01 to SH-FR-221 (SH-FR-05 and SH-FR-79 Deleted), SH-BR-01 to SH-BR-18, SH-E-01 to SH-E-48, SH-AC-01 to SH-AC-66, SH-NFR-01 to SH-NFR-15, SH-CC-01 to SH-CC-16, SH-A-01 to SH-A-34, SH-R-01 to SH-R-06, SH-DOC-01 to SH-DOC-15, SH-Q1 to SH-Q13 (answered 2026-10-10) |
