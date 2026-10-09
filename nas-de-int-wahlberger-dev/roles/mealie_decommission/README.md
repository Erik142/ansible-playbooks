# mealie_decommission

Idempotently stops and removes a live Mealie systemd unit and Podman
container left over from before the Tandoor cut-over.

## Why this role exists

The `mealie` role is deleted from this repository as part of the same
change that adds Tandoor Recipes (`roles/tandoor/`), so it can no longer
manage its own teardown. `mealie_decommission` is the small, standalone
piece of code that survives after `roles/mealie/` is gone and does the
actual host-side cleanup (FR-37, FR-38, FR-82 in
`nas-de-int-wahlberger-dev/reqs/tandoor-replaces-mealie.md`).

## What it does

1. Checks whether `/etc/containers/systemd/mealie.container` exists.
2. If it does: stops and disables `mealie.service`, removes the `mealie`
   Podman container, removes the unit file, and reloads the systemd
   daemon.
3. If it does not (Mealie was never deployed on this host, or a previous
   run already removed it): every task above is skipped, and the run
   reports `changed=0` for this role.

Every task is conditioned on the same `stat` result, so a second run
against an already-decommissioned host is a clean no-op — it never reports
`changed`, and never fails just because Mealie is already gone.

## What it deliberately does not do

It never creates, modifies or deletes `/mnt/containers/mealie` or any path
below it (FR-46). That directory holds the only copy of Mealie's data
during the rollback window (see `nas-de-int-wahlberger-dev/reqs/tandoor-replaces-mealie.md`'s
`BR-01`), and its deletion is an explicit manual owner step, documented in
`roles/tandoor/README.md`, run once BR-01 is met. No task in this repo,
including this role, is allowed to touch that path.

## Role variables

None. The paths and names this role acts on
(`/etc/containers/systemd/mealie.container`, `mealie.service`, the
`mealie` Podman container) are fixed by what `roles/mealie/` used to
deploy — they are not configurable. See `defaults/main.yml`.

## Wiring

This role is not wired into `site.yml` by itself — see
`nas-de-int-wahlberger-dev/PLAN.md` task T-09, which adds
`- role: mealie_decommission` (suggested tags: `[mealie_decommission]`),
positioned before Caddy's route flips from `mealie` to `tandoor`, or
documented as order-irrelevant if neither publishes a host port at the
time T-09 lands (neither does, per `roles/mealie/templates/mealie.container.j2`
and `roles/tandoor/templates/tandoor.container.j2`'s `FR-49`/`FR-50`
no-`PublishPort=` requirement — no port clash either order).
