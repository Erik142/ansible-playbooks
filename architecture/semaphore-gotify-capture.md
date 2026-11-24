# Semaphore → Gotify request, captured 2026-11-24

Captured on ops with a logging receiver, after pressing **Test alerts** in the Semaphore UI (project Homelab, version 2.19.17). Token value in the sample was a test value.

```
POST /message?token=capture-token-only
Content-Type: application/json
User-Agent: Go-http-client/1.1

{
  "extras": {"client::display": {"contentType": "text/markdown"}},
  "message": "Execution #: 0   \nStatus: ✅ SUCCESS   \nAuthor: —   \n[Task Link](/project/1/templates/0?t=0)",
  "title": "Task: Test Notification"
}
```

- The token is a **query parameter** (`?token=`), not a header.
- Body: `title` (`Task: <template name>`), `message` (markdown: execution number, status, author, task link), `extras`.
- The status text comes from the Semaphore template `execution #{{ .Task.ID }}, status: {{ .Task.Result }}`. The success string was captured as `✅ SUCCESS`. The failure string has **not** been captured yet, so it must be checked with a real failed run before anything depends on it.
- Project alerts have a `suppress_success_alerts` setting. The Semaphore UI on this version doesn't show it.

## What this means for Hush
The Gotify request isn't a Hush event. Hush needs a source adapter to accept it. See the Hush prompt in the PR description.
