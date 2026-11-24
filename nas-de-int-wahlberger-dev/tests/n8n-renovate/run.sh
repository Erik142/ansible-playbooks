#!/usr/bin/env bash
# Tests the Renovate gate in monitor-only mode (roles/n8n/files/renovate-gate-workflow.json)
# against a stubbed GitHub (fixed PRs, records every request) and the Claude stub.
# Asserts the decision for each PR and that the workflow made no write to GitHub.
#
# Usage: tests/n8n-renovate/run.sh <n8n-image>
set -euo pipefail

IMAGE=${1:?usage: run.sh <n8n-image>}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$HERE/../../roles/n8n/files
TESTS=$HERE/..
PORT=${PORT:-5694}
ID=$$
NET=n8n-renovate-net-$ID
N8N=n8n-renovate-n8n-$ID
GH=n8n-renovate-gh-$ID
CLAUDE=n8n-renovate-claude-$ID
VOL=n8n-renovate-data-$ID
WORK=$(mktemp -d)
BASE=http://127.0.0.1:$PORT
OWNER=renovate-test-owner@example.test
GHTOKEN=test-token-$ID
ENCKEY=$(openssl rand -hex 32)
printf %s "$ENCKEY" >"$WORK/encryption.key"
fail=0

cleanup() {
  docker rm -f "$N8N" "$GH" "$CLAUDE" >/dev/null 2>&1 || true
  docker volume rm "$VOL" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "PASS $1 ($3)"; else echo "FAIL $1: expected $2, got $3"; fail=1; fi
}
wait_for() { local what=$1; shift; for _ in $(seq 1 60); do if "$@" >/dev/null 2>&1; then return 0; fi; sleep 2; done; echo "FAIL $what did not become ready"; return 1; }

echo "image: $IMAGE"
docker network create "$NET" >/dev/null
docker run -d --name "$GH" --network "$NET" -v "$TESTS/n8n-renovate/github_stub.py:/stub.py:ro" \
  python:3.12-alpine python /stub.py 8080 >/dev/null
docker run -d --name "$CLAUDE" --network "$NET" -v "$TESTS/n8n-triage/claude_stub.py:/stub.py:ro" \
  python:3.12-alpine python /stub.py 8080 >/dev/null
wait_for "github stub" docker exec "$GH" python -c 'import urllib.request;urllib.request.urlopen("http://127.0.0.1:8080/_requests")'
wait_for "claude stub" docker exec "$CLAUDE" python -c 'import urllib.request;urllib.request.urlopen("http://127.0.0.1:8080/_requests")'

ENV_ARGS=(-e N8N_DIAGNOSTICS_ENABLED=false -e N8N_VERSION_NOTIFICATIONS_ENABLED=false -e N8N_TEMPLATES_ENABLED=false -e N8N_PERSONALIZATION_ENABLED=false
  -e NODE_FUNCTION_ALLOW_BUILTIN=crypto -e N8N_BLOCK_ENV_ACCESS_IN_NODE=false
  -e N8N_ENCRYPTION_KEY_FILE=/run/secrets/n8n_encryption_key
  -e GITHUB_API_URL=http://$GH:8080 -e GITHUB_TOKEN_MONITOR="$GHTOKEN"
  -e ANTHROPIC_API_KEY=test-anthropic-key -e ANTHROPIC_BASE_URL=http://$CLAUDE:8080)
docker run -d --name "$N8N" --network "$NET" -p "127.0.0.1:$PORT:5678" -v "$VOL:/home/node/.n8n" \
  -v "$WORK/encryption.key:/run/secrets/n8n_encryption_key:ro" "${ENV_ARGS[@]}" "$IMAGE" >/dev/null
wait_for "n8n" bash -c "curl -sf $BASE/healthz"

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
check "owner setup" 200 "$(code -X POST "$BASE/rest/owner/setup" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$OWNER\",\"firstName\":\"Renovate\",\"lastName\":\"Test\",\"password\":\"RenovateTest-123456\"}")"

# Import while n8n is stopped, after its startup migrations (same pattern as the triage test).
wait_for "n8n startup migrations" bash -c "docker logs $N8N 2>&1 | grep -q 'Editor is now accessible'"
docker stop "$N8N" >/dev/null
docker run --rm --entrypoint sh -v "$VOL:/home/node/.n8n" -v "$ROOT/renovate-gate-workflow.json:/tmp/wf.json:ro" \
  -v "$WORK/encryption.key:/run/secrets/n8n_encryption_key:ro" "${ENV_ARGS[@]}" "$IMAGE" \
  -c 'n8n import:workflow --input=/tmp/wf.json && n8n update:workflow --id=n8nrenovate01 --active=true'
docker start "$N8N" >/dev/null
wait_for "n8n after import" bash -c "curl -sf $BASE/healthz"
sleep 5

resp=$(curl -s -X POST "$BASE/webhook/renovate-poll" -H 'Content-Type: application/json' -d '{}')
python3 - "$resp" "$GHTOKEN" <<'PY' || fail=1
import json, sys
resp, token = sys.argv[1], sys.argv[2]
body = json.loads(resp)
assert body.get("mode") == "monitor-only", body
by_pr = {d["pr"]: d for d in body["decisions"]}
expected = {7: "would_merge", 8: "escalate", 10: "escalate", 11: "wait"}
for pr, want in expected.items():
    got = by_pr.get(pr, {}).get("decision")
    print(("PASS" if got == want else "FAIL"), f"PR {pr} decision", want, "got", got)
    if got != want:
        raise SystemExit(1)
assert 9 not in by_pr, "a non-Renovate PR must be ignored"
print("PASS non-Renovate PR ignored")
assert "major" in " ".join(by_pr[8]["reasons"]), by_pr[8]
assert "denylisted" in " ".join(by_pr[10]["reasons"]), by_pr[10]
print("PASS escalation reasons recorded (major, denylist)")
assert token not in resp, "token leaked into the response"
print("PASS token not in the response")
PY
gh_requests=$(docker exec "$GH" python -c 'import urllib.request;print(urllib.request.urlopen("http://127.0.0.1:8080/_requests").read().decode())')
claude_requests=$(docker exec "$CLAUDE" python -c 'import urllib.request;print(urllib.request.urlopen("http://127.0.0.1:8080/_requests").read().decode())')
python3 - "$gh_requests" "$claude_requests" "$GHTOKEN" <<'PY' || fail=1
import json, sys
gh, claude, token = json.loads(sys.argv[1]), json.loads(sys.argv[2]), sys.argv[3]
writes = [r for r in gh if r["method"] != "GET"]
assert not writes, f"writes to GitHub: {writes}"
print(f"PASS no writes to GitHub ({len(gh)} GET requests)")
assert all(r["authorization"] == "Bearer " + token for r in gh), "token not sent on every GitHub request"
print("PASS the monitoring token is sent on every GitHub request")
reviews = [c for c in claude if "merge safety" in json.dumps(c.get("body", {}))]
assert len(reviews) == 1, f"expected one review (PR 7), got {len(reviews)}"
print("PASS one Claude review, for the one PR that passed the classifier")
PY

if [ "$fail" = 0 ]; then echo "ALL PASS: n8n-renovate monitor-only ($IMAGE)"; else echo "FAILURES: n8n-renovate ($IMAGE)"; fi
exit "$fail"
