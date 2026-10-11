# Spike A-09 / A-31 / A-32: Semaphore image facts, `semaphoreui/semaphore:v2.19.16`

Date 2026-10-10. Spec: SH-A-09, SH-A-31, SH-A-32 (inputs to SH-FR-91, SH-FR-166..169, SH-FR-210, SH-AC-53, tasks T-13 and T-09). Evidence level: local container, throwaway SQLite, throwaway admin; the admin password, cookie secrets and token existed only inside the throwaway container (deleted). Nothing touched a real host. Same tag as `pi-de-int-wahlberger-dev/roles/semaphore/defaults/main.yml`.

## Method
```
docker run -d --name t03-sem -p 127.0.0.1:13000:3000 -v t03-sem:/var/lib/semaphore \
  -e SEMAPHORE_DB_DIALECT=sqlite -e SEMAPHORE_DB_HOST=/var/lib/semaphore/database.sqlite \
  -e SEMAPHORE_ADMIN=... -e SEMAPHORE_ADMIN_PASSWORD=... -e SEMAPHORE_ADMIN_NAME=... -e SEMAPHORE_ADMIN_EMAIL=... \
  -e SEMAPHORE_COOKIE_HASH/_COOKIE_ENCRYPTION/_ACCESS_KEY_ENCRYPTION=$(openssl rand -base64 32) \
  semaphoreui/semaphore:v2.19.16
```
Then sample data via the API (one project, key, repository, inventory, environment, template, schedule, 3 tasks).

## A-09: `/api/ping`
`curl -si http://127.0.0.1:13000/api/ping` without login -> `HTTP/1.1 200 OK`, `Content-Type: text/plain`, body `pong`. `HEAD /api/ping` -> 200. `GET /` -> 200. Unauthenticated `GET /api/projects` -> 401.
Decision: FR-91's monitor can use `/api/ping` (expects 200, keyword `pong`); no fallback to `/` needed.

## A-32: UID
- Image config: `User=1001`; Entrypoint `/sbin/tini --`, Cmd `server-wrapper`.
- `docker exec t03-sem id -u` -> `1001`; `ps`: tini (PID 1) and `/usr/local/bin/semaphore server --config /etc/semaphore/config.json` both run as `semaphore` (uid 1001, gid 0).
- Files the process creates in the data dir: `database.sqlite`, `-shm`, `-wal`, owner `1001:0`, mode 0644 (so the role must set 0600/0700 itself; the Quadlet must not rely on image defaults).
- `/var/lib/semaphore`, `/etc/semaphore`, `/tmp/semaphore` are owned `semaphore:root` in the image.
Decision: expected `semaphore_uid` is `1001` for this tag. The authoritative values are the Pi read in step 3 (`podman exec semaphore id -u`) and the VM check (AC-53); this is an input to compare against, not a replacement. Note the Pi run uses a bind-mounted data dir with `:Z`; with rootful Podman and no `userns` mapping the UID stays 1001 on the host.

## A-31: API endpoints for the step-4 record
Login: `POST /api/auth/login` `{"auth":"<user>","password":"<pw>"}` -> 204 + session cookie. Alternative: `POST /api/user/tokens` (with the session) -> `{"id":"<token>"}`; `Authorization: Bearer <token>` -> 200. T-13 can use either (token avoids storing a cookie jar; both need a credential that must not be printed).

| Count | Endpoint (all GET, 200) | Notes |
|---|---|---|
| projects | `/api/projects` | list |
| keys | `/api/project/{id}/keys` | a new project already contains one auto-created key `None` (type none); it counts. List shows no secret values for type none; do not log the response for real keys |
| repositories | `/api/project/{id}/repositories` | |
| inventories | `/api/project/{id}/inventory` | singular path |
| environments | `/api/project/{id}/environment` | singular path |
| templates | `/api/project/{id}/templates` | contains `last_task` |
| schedules | `/api/project/{id}/schedules` | fields: `id, template_id, cron_format, name, active, tpl_name`. `GET /api/schedules` is 404 (no global list) |
| users | `/api/users` | admin only; fields `id, username, name, email, admin, external` |
| tasks | `/api/project/{id}/tasks` | list sorted newest first: observed `[3,2,1]`; `?limit=1` is ignored (returns all). Also `/api/project/{id}/tasks/last` (returned the same 1 to 3 rows here; its cap was not tested) |
| version | `/api/info` | `version` `v2.19.16-f8cefe6-...` and bundled ansible core 2.20.10 |

- Newest task id (FR-53, AC-20): `max(id)` over `/api/project/{id}/tasks` for every project. Do not use `GET /api/tasks`: it returned `[]` (queue of running/waiting tasks only).
- Active schedules (FR-101): count items with `"active": true` in each project's `/schedules`.
- Task rows are created even when the run fails (status `error` here: repository `/nonexistent`), so a `--check` run of templates on the VM would create rows; this is why PA-2 puts the comparison first.
- Counts are per project: T-13 must iterate `/api/projects`.

## Decision
`/api/ping` is a valid unauthenticated 200 probe; UID for v2.19.16 is 1001 (compare with Pi and VM); the table above is the T-13 endpoint list. Affects: T-13 (primary), T-09 (uid, modes), T-12/T-17 (FR-91 monitor URL).
