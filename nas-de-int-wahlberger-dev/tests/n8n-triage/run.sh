#!/usr/bin/env bash
# Tests the phase 2a triage workflow (roles/n8n/files/triage-workflow.json) end to end:
# real n8n image, real forced command over SSH (sshd container), Claude API stub.
# Fixtures are signed the way Hush signs handoffs. Each check asserts on the HTTP reply
# and on what the Claude stub received, so a leaked hostname or a missed signature check fails.
#
# Usage: tests/n8n-triage/run.sh <n8n-image>
set -euo pipefail

IMAGE=${1:?usage: run.sh <n8n-image>}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$HERE/../../roles/n8n/files
PORT=${PORT:-5692}
ID=$$
NET=n8n-triage-net-$ID
N8N=n8n-triage-n8n-$ID
SSHD=n8n-triage-sshd-$ID
CLAUDE=n8n-triage-claude-$ID
VOL=n8n-triage-data-$ID
WORK=$(mktemp -d)
BASE=http://127.0.0.1:$PORT
HOST=nas.de.int.wahlberger.dev
OWNER=triage-test-owner@example.test
SECRET=$(openssl rand -hex 32)
ENCKEY=$(openssl rand -hex 32)
printf %s "$ENCKEY" >"$WORK/encryption.key"
ANTH=test-anthropic-key
fail=0

cleanup() {
  docker rm -f "$N8N" "$SSHD" "$CLAUDE" >/dev/null 2>&1 || true
  docker volume rm "$VOL" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "PASS $1 ($3)"; else echo "FAIL $1: expected $2, got $3"; fail=1; fi
}

wait_for() { # description, command...
  local what=$1; shift
  for _ in $(seq 1 60); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  echo "FAIL $what did not become ready"
  return 1
}

echo "image: $IMAGE"
docker network create "$NET" >/dev/null
ssh-keygen -q -t ed25519 -N "" -f "$WORK/n8n-diag"
mkdir -p "$WORK/keys" && cp "$WORK/n8n-diag.pub" "$WORK/keys/n8n-diag.pub"

docker run -d --name "$SSHD" --network "$NET" \
  -v "$WORK/keys:/keys:ro" -v "$ROOT:/diag:ro" -v "$HERE/sshd-setup.sh:/setup.sh:ro" \
  alpine:3.20 /bin/sh /setup.sh >/dev/null
wait_for "sshd" docker exec "$SSHD" sh -c 'nc -z 127.0.0.1 22'

docker run -d --name "$CLAUDE" --network "$NET" -v "$HERE/claude_stub.py:/stub.py:ro" \
  python:3.12-alpine python /stub.py 8080 >/dev/null
wait_for "claude stub" docker exec "$CLAUDE" python -c 'import urllib.request;urllib.request.urlopen("http://127.0.0.1:8080/_requests")'

docker run -d --name "$N8N" --network "$NET" -p "127.0.0.1:$PORT:5678" -v "$VOL:/home/node/.n8n" \
  -v "$WORK/encryption.key:/run/secrets/n8n_encryption_key:ro" \
  -e N8N_ENCRYPTION_KEY_FILE=/run/secrets/n8n_encryption_key \
  -e N8N_DIAGNOSTICS_ENABLED=false -e N8N_VERSION_NOTIFICATIONS_ENABLED=false \
  -e N8N_TEMPLATES_ENABLED=false -e N8N_PERSONALIZATION_ENABLED=false \
  -e NODE_FUNCTION_ALLOW_BUILTIN=crypto -e N8N_BLOCK_ENV_ACCESS_IN_NODE=false \
  -e HUSH_N8N_SECRET="$SECRET" -e ANTHROPIC_API_KEY="$ANTH" \
  -e ANTHROPIC_BASE_URL="http://$CLAUDE:8080" \
  "$IMAGE" >/dev/null
wait_for "n8n" bash -c "curl -sf $BASE/healthz"

# Owner and credential, then the workflow. The SSH key is the one whose public half
# is authorised in the sshd container.
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
check "owner setup" 200 "$(code -X POST "$BASE/rest/owner/setup" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$OWNER\",\"firstName\":\"Triage\",\"lastName\":\"Test\",\"password\":\"TriageTest-123456\"}")"

python3 - "$WORK/n8n-diag" "$SSHD" >"$WORK/credentials.json" <<'PY'
import json, sys
key = open(sys.argv[1]).read()
print(json.dumps([{
    "id": "n8ndiagssh01", "name": "n8n-diag", "type": "sshPrivateKey",
    "data": {"host": sys.argv[2], "port": 22, "username": "n8n-diag",
             "sshAuthenticateWith": "privateKey", "privateKey": key, "passphrase": ""},
}]))
PY
# Imports run in a one-off container while n8n is stopped: the server and the CLI must
# not migrate the same SQLite volume at the same time.
# Wait until the server has finished its startup migrations before stopping it.
wait_for "n8n startup migrations" bash -c "docker logs $N8N 2>&1 | grep -q 'Editor is now accessible'"
docker stop "$N8N" >/dev/null
docker run --rm --name "$N8N-import" --entrypoint sh -v "$VOL:/home/node/.n8n" \
  -v "$WORK/credentials.json:/tmp/credentials.json:ro" \
  -v "$ROOT/triage-workflow.json:/tmp/triage-workflow.json:ro" \
  -v "$WORK/encryption.key:/run/secrets/n8n_encryption_key:ro" \
  -e N8N_ENCRYPTION_KEY_FILE=/run/secrets/n8n_encryption_key -e N8N_DIAGNOSTICS_ENABLED=false \
  -e N8N_VERSION_NOTIFICATIONS_ENABLED=false -e N8N_TEMPLATES_ENABLED=false \
  -e N8N_PERSONALIZATION_ENABLED=false \
  "$IMAGE" -c 'n8n import:credentials --input=/tmp/credentials.json && n8n import:workflow --input=/tmp/triage-workflow.json && n8n update:workflow --id=n8ntriage01 --active=true'
docker start "$N8N" >/dev/null
wait_for "n8n after restart" bash -c "curl -sf $BASE/healthz"
sleep 5

sign() { # <timestamp> <body> -> hex signature
  printf '%s.%s' "$1" "$2" | openssl dgst -sha256 -hmac "$SECRET" -hex | awk '{print "sha256=" $NF}'
}
now() { date +%s; }
handoff() { # <kind> <host> <service> <check> <schema> -> JSON body
  python3 -c '
import json, sys
kind, host, service, check, schema = sys.argv[1:6]
print(json.dumps({
  "schema_version": int(schema), "delivery_id": "3f1c2d4e-0000-4000-8000-000000000001",
  "kind": kind, "problem_key": f"{host}/{service}/{check}", "decision_id": 42,
  "host": host, "service": service, "check": check, "check_key": check, "source": "hooks-nas",
  "severity": "warning", "status": "problem", "first_seen": "2026-11-24T09:00:00+01:00",
  "last_seen": "2026-11-24T09:05:00+01:00", "streak": 3,
  "summary": f"{service} keeps failing on {host}", "raw_excerpt": f"connect to 192.168.10.5 failed on {host}",
  "reply": None if kind == "info" else {"url": "https://hush.de.int.wahlberger.dev/ingest/remediation", "reply_by": "2026-11-24T10:00:00+01:00"},
  "held": kind == "alert", "shadow": False}))' "$1" "$2" "$3" "$4" "${5:-1}"
}
post() { # <body> <signature> [timestamp] -> prints "code<TAB>response"
  local body=$1 sig=$2 ts=${3:-$(now)}
  curl -s -w '\n%{http_code}' -X POST "$BASE/webhook/hush" -H 'Content-Type: application/json' \
    -H "X-Hush-Timestamp: $ts" -H "X-Hush-Signature: $sig" --data-binary "$body"
}
claude_requests() { docker exec "$CLAUDE" python -c 'import urllib.request;print(urllib.request.urlopen("http://127.0.0.1:8080/_requests").read().decode())'; }
claude_count() { claude_requests | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))'; }

# 1. A valid info handoff for the NAS, with an allowlisted service: triaged and escalated.
body=$(handoff info "$HOST" n8n http)
ts=$(now); resp=$(post "$body" "$(sign "$ts" "$body")" "$ts")
check "valid info handoff accepted" 200 "$(tail -1 <<<"$resp")"
if grep -q '"outcome":"escalate"' <<<"$resp"; then echo "PASS reply is outcome escalate"; else echo "FAIL reply is not escalate: $resp"; fail=1; fi
if grep -q '"proposed_action":"restart caddy.service"' <<<"$resp"; then
  echo "PASS PROPOSED_ACTION is recorded in the reply"
else
  echo "FAIL PROPOSED_ACTION not in the reply: $resp"; fail=1
fi
reqs=$(claude_requests)
python3 - "$reqs" "$HOST" <<'PY' || fail=1
import json, sys
reqs, host = json.loads(sys.argv[1]), sys.argv[2]
assert len(reqs) == 1, f"expected one Claude call, got {len(reqs)}"
r = reqs[0]
prompt = r["body"]["messages"][0]["content"]
assert r["headers"].get("x-api-key") == "test-anthropic-key", "x-api-key not sent"
assert host not in prompt, "hostname leaked into the Claude prompt; tail: " + prompt[-700:]
assert "192.168.10.5" not in prompt, "IP address leaked into the Claude prompt"
assert "<host>" in prompt, "redaction marker missing"
assert "stub systemctl" in prompt, "diagnostics from the forced command missing; prompt tail: " + prompt[-400:]
print("PASS prompt redacted and includes the diagnostics")
PY

# 2. Bad signature, stale timestamp, tampered body: all 401, no Claude call.
before=$(claude_count)
body=$(handoff info "$HOST" n8n http)
check "wrong signature rejected" 401 "$(tail -1 <<<"$(post "$body" "sha256=00")")"
ts=$(( $(now) - 1000 ))
check "stale timestamp rejected" 401 "$(tail -1 <<<"$(post "$body" "$(sign "$ts" "$body")" "$ts")")"
ts=$(now); other=$(handoff info "$HOST" caddy http)
check "signature over another body rejected" 401 "$(tail -1 <<<"$(post "$other" "$(sign "$ts" "$body")" "$ts")")"
check "no Claude call after rejected requests" "$before" "$(claude_count)"

# 3. Signed but malformed: 400. Alert handoff: 409 (not handled in phase 2a). No Claude call either.
body=$(handoff info "$HOST" n8n http 2)
ts=$(now); check "unknown schema_version rejected" 400 "$(tail -1 <<<"$(post "$body" "$(sign "$ts" "$body")" "$ts")")"
body=$(handoff alert "$HOST" n8n http)
ts=$(now); check "alert handoff answered 409" 409 "$(tail -1 <<<"$(post "$body" "$(sign "$ts" "$body")" "$ts")")"
check "no Claude call after 400 and 409" "$before" "$(claude_count)"

# 4. Not on the NAS, or a unit the forced command refuses: still triaged (no diagnostics).
body=$(handoff info "lab-box.example.test" caddy http)
ts=$(now); check "non-NAS host still triaged" 200 "$(tail -1 <<<"$(post "$body" "$(sign "$ts" "$body")" "$ts")")"
body=$(handoff info "$HOST" forgejo http)
ts=$(now); check "unlisted unit still triaged" 200 "$(tail -1 <<<"$(post "$body" "$(sign "$ts" "$body")" "$ts")")"
python3 - "$(claude_requests)" <<'PY' || fail=1
import json, sys
reqs = json.loads(sys.argv[1])[1:]
assert len(reqs) == 2, len(reqs)
for r in reqs:
    assert "(none: not available" in r["body"]["messages"][0]["content"], "diagnostics should be absent"
print("PASS no diagnostics when the host or unit is not allowed")
PY

# 5. Secrets never leave n8n in a reply or a prompt.
if grep -q "$SECRET" <<<"$(curl -s -X POST "$BASE/webhook/hush" -d '{}')$(claude_requests)"; then
  echo "FAIL HMAC secret leaked"; fail=1
else
  echo "PASS HMAC secret not in replies or prompts"
fi

if [ "$fail" = 0 ]; then echo "ALL PASS: n8n-triage ($IMAGE)"; else echo "FAILURES: n8n-triage ($IMAGE)"; fi
exit "$fail"
