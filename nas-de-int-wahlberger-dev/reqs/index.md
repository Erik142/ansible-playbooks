# Requirements — nas-de-int-wahlberger-dev

One line per file. Read this file first to know what exists.

| File | Feature | Status | Version | Scope | Quality |
|---|---|---|---|---|---|
| [tandoor-replaces-mealie.md](tandoor-replaces-mealie.md) | Replace Mealie with Tandoor Recipes | ready | 1.3 | Tandoor deployment, Pocket ID sign-in, Mealie decommission. Backup items are superseded by the backup feature (markers in the file) | 5,5,5,5,5,5,5,5 (2026-09-27) |
| [backup-overview.md](backup-overview.md) | Local backup disk, btrbk, NAS-hosted restic REST server | ready | 3.0 | Problem, terms, constraints, decisions, contract changes, assumptions, cross-cutting FRs/BRs/scenarios, NFRs, out of scope, decision log | 4,5,4,4,5,5,4,5 (2026-10-09, whole feature) |
| [backup-disk-init.md](backup-disk-init.md) | same | ready | 3.0 | Init playbook and refusal rules, VM gate, `backup_disk` role: mount `@btrbk`, scrub, smartd, health check, disk_space | see overview |
| [backup-btrbk-and-db-dump.md](backup-btrbk-and-db-dump.md) | same | ready | 3.0 | btrbk install, replication and retention of `/mnt/data` (including the restic repositories) and `/mnt/containers`; `db_dump` | see overview |
| [backup-restic-server.md](backup-restic-server.md) | same | ready | 3.0 | rest-server at `/mnt/data/restic-repos`, append-only, quota, firewall (10.10.0.0/16, 10.243.0.0/16), maintenance run, prune guard | see overview |
| [backup-cutover-and-decommission.md](backup-cutover-and-decommission.md) | same | ready | 3.0 | Runbook, cut-over flags, retirement of the NAS→Pi restic job, cloud changes, wiring, documentation, render check, VM fixture | see overview |
| [smartd-main-disk.md](smartd-main-disk.md) | smartd monitoring of the main data HDD | ready | 1.0 | Generic `smartd` role: device list, shared mail hook and service (reused by `backup_disk`), runs ungated | not scored |

## ID map

The Tandoor IDs have no prefix. Backup feature IDs carry the prefix `BD-`; "[Deleted]" IDs are kept and never reused.

| File | IDs |
|---|---|
| tandoor-replaces-mealie.md | FR-01 to FR-85, BR-01 to BR-09, NFR-01 to NFR-11, AC-01 to AC-53, A-01 to A-13, C-01 to C-05 |
| backup-overview.md | BD-C-01 to BD-C-05, BD-D-01 to BD-D-17, BD-CC-01 to BD-CC-09, BD-A-01 to BD-A-23; BD-FR-25, BD-FR-27, BD-FR-28, BD-FR-33; BD-BR-04, BD-BR-05; BD-NFR-01 to BD-NFR-12; BD-AC-01 to BD-AC-03, BD-AC-27, BD-AC-57 to BD-AC-60, BD-AC-80, BD-AC-84 to BD-AC-87 |
| backup-disk-init.md | BD-FR-01 to BD-FR-16, BD-FR-20 to BD-FR-24, BD-FR-26, BD-FR-29 to BD-FR-32, BD-FR-34 to BD-FR-46, BD-FR-159; BD-BR-01 to BD-BR-03, BD-BR-12; BD-AC-04, BD-AC-20 to BD-AC-24, BD-AC-26, BD-AC-28, BD-AC-55, BD-AC-56, BD-AC-82 |
| backup-btrbk-and-db-dump.md | BD-FR-47 to BD-FR-76, BD-FR-161 to BD-FR-168; BD-BR-11, BD-BR-15; BD-AC-15, BD-AC-29 to BD-AC-37, BD-AC-83, BD-AC-88 to BD-AC-92 |
| backup-restic-server.md | BD-FR-87 to BD-FR-121, BD-FR-122 and BD-FR-123 (Deleted), BD-FR-160; BD-BR-06 to BD-BR-10; BD-AC-08, BD-AC-39 to BD-AC-52, BD-AC-53 (Deleted), BD-AC-54 |
| backup-cutover-and-decommission.md | BD-FR-17, BD-FR-18, BD-FR-19 (Deleted), BD-FR-77 to BD-FR-86, BD-FR-124 to BD-FR-158; BD-BR-13, BD-BR-14; BD-AC-05 to BD-AC-07, BD-AC-09 to BD-AC-14, BD-AC-16, BD-AC-25, BD-AC-38, BD-AC-81 |
| smartd-main-disk.md | SM-FR-1 to SM-FR-8, SM-AC-01 to SM-AC-04 |
