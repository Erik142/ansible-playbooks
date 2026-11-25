# n8n triage workflow (phase 2, read-only)

Status: proposed, 2026-11-24. Implements phase 2 of [`ai-incident-remediation-pipeline.md`](ai-incident-remediation-pipeline.md) and `nas-de-int-wahlberger-dev/PLAN-n8n.md` (directory removed from the repo; see git history). Hush side: HUSH-NOTIFY-040 to -048, HUSH-INGEST-036 to -042 (hush 1.2.1).

## Principle: Hush's decisions do not change
Erik's constraint: the triage must not change what Hush does. Two rules make that hold:

1. **No holds.** `remediation.routes` is empty, so no problem is held (HUSH-RULES-069: holds only on a route match). E-mail timing is unchanged.
2. **n8n never resolves.** Every reply is `outcome: escalate` with the triage report. Hush's own rules decide the rest, as before.

Consequence: with empty routes, the workflow receives only `info` handoffs (HUSH-NOTIFY-043: `always_notify` problems, critical problems, and shadow-mode notifies). Those are triaged and reported, but nothing waits for them. Held alerts are not triaged until routes are chosen. Choosing routes changes e-mail timing, so that is a separate decision for Erik.

Shadow mode is not used. It turns off Hush's decisions for the whole instance.

## Hush config change (the only change on ops)
Added to the hush config (ops `hush_config`, rendered by the hush role). Nothing else in Hush changes.

```yaml
notifications:
  webhook:
    url: https://n8n.de.int.wahlberger.dev/webhook/hush
    secret: /run/secrets/hush_webhook        # HMAC key shared with n8n (vault_hush_webhook_secret)
    timeout: 10
    attempts: 3
remediation:
  enabled: true
  routes: []                                  # no holds: decisions and e-mail timing unchanged
```

Secret values come from the ops vault. Hush 1.2.1 contains the code. Verify with a test handoff before relying on it.

## Flow (per handoff)
1. **Receive** `POST /webhook/hush`. Verify `X-Hush-Signature` (HMAC-SHA256 over `X-Hush-Timestamp.body`, key `hush_webhook`). Reject with 401 if it fails or the timestamp is more than 300 s old.
2. **Validate** the body against the HUSH-NOTIFY-042 member list. Reject unknown shapes with 400 and do not call anything else.
3. **Diagnostics** (only if `host` is in the allowlist): SSH to the host with the `n8n-diag` key and the forced command `n8n-diag-bundle <unit>`. Units come from the allowlist in the diag script. Output is capped at 8 KiB.
4. **Triage** (one Claude call per handoff, `claude-haiku-5-5`, `max_tokens` 1024): the fixed template below, with redacted input. Hostnames in the diagnostics are replaced by `<host>` before the call, and so are IPv4 addresses. Secret values never reach the payload (HUSH-NOTIFY-047).
5. **Reply**: for `info` handoffs nothing is sent back (`reply: null`). If a future `alert` handoff arrives, reply to `POST https://hush.de.int.wahlberger.dev/ingest/remediation` with `outcome: escalate`, the summary, and the signed reply credential (`remediation.secret`).

Failure behaviour: any error in steps 3–5 ends the run without a reply. Hush retries info handoffs up to `notifications.webhook.attempts` (3) and never holds anything for them. Hush's e-mail is unaffected.

## Prompt template (fixed)
Role: read-only incident triage for a homelab. Given the Hush event, the host diagnostics and nothing else, state the most likely cause class, the evidence, and one next check to run by hand. Do not propose changes to hosts. Answer in at most 12 lines.

## Allowlists and limits
- Diagnostics: only the units in `n8n-diag-bundle` (the script on each host). The NAS list is the units with an `OnFailure=` hook.
- Hosts: only `nas-de-int-wahlberger-dev` in phase 2a. Other hosts follow after the NAS run is verified.
- Outbound: `api.anthropic.com` and the hush and n8n hosts only.

## Scope of phase 2a
In: webhook, HMAC, validation, NAS diagnostics, Claude triage, `escalate`-only output.
Out, for now: recent GitHub commits (needs a read token and the Semaphore CVE check), last Semaphore task (same), other hosts' diagnostics, any reply that is not `escalate`.

## Tests
- CI job `n8n-hook` extended: the workflow is imported into a test n8n 2.48.8 (`tests/n8n-triage/`). Stubs stand in for Claude and the diagnostics. The test asserts: bad signature 401; malformed body 400; a valid handoff is triaged; the stub Claude request contains no hostname from the fixture; the reply, if any, is `escalate`.
- `diag-bundle` unit test: an unlisted unit is refused.

## Success criteria before any further step
Over two to four weeks of `info` handoffs, the triage matches the root causes found by hand. Only then consider routes (held alerts, which change e-mail timing) and phase 3.
