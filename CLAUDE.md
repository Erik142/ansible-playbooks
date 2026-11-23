# ansible-playbooks (repo root)

Per-playbook details live in each directory's own `CLAUDE.md`. This file covers rules for the whole repo.

## CI testing

- Always use `act` (nektos/act) to test changes to `.github/workflows/`. Run the affected jobs locally before pushing, e.g. `act pull_request -W .github/workflows/ci.yml -j ops-static`. Simulated runs (calling the scripts directly) are not a substitute: `act` runs the real workflow YAML, including step order, `if:` conditions, cache steps and job dependencies.
- Report what `act` could not reproduce (runner image differences, missing secrets, GitHub-only contexts) instead of hiding it.
