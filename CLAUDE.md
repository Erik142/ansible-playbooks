# ansible-playbooks (repo root)

Per-playbook details live in each directory's own `CLAUDE.md`. This file covers rules for the whole repo.

## CI testing

- Always use `act` (nektos/act) to test changes to `.github/workflows/`. Run the affected jobs locally before pushing, e.g. `act pull_request -W .github/workflows/ci.yml -j ops-static`. Simulated runs (calling the scripts directly) are not a substitute: `act` runs the real workflow YAML, including step order, `if:` conditions, cache steps and job dependencies.
- Report what `act` could not reproduce (runner image differences, missing secrets, GitHub-only contexts) instead of hiding it.

## Hush recovery lists (mandatory)

`roles/hush_recovery/defaults/main.yml` (`hush_recovery_units`) must list every long-running unit that has `OnFailure=notify-failure@%n.service`. Without the entry, Hush gets the failure but never the recovery, so the problem stays open and escalates on every cycle.

- **Whenever a service is added, removed, renamed or its unit name changes**, update this list in the same change. Check with `grep -rl "OnFailure=notify-failure" roles` against the list.
- One-shot units (timers, backup and check jobs) are not listed. A drop-in restarts the unit, which is wrong for them.
- On ops, `caddy.service` and `semaphore.service` are covered by `hush_systemd_watched_units` in the `hush` role. Do not duplicate them here.
- Deploying a changed list restarts the listed units whose drop-in changed. For `zerotier.service`, that briefly drops ZeroTier connectivity, so run it in a window where that is acceptable.
