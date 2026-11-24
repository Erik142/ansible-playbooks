#!/usr/bin/env bash
# Tests the n8n trusted-header hook (roles/n8n/files/hooks.js) against one n8n image.
# Same steps as the manual NAS test: owner setup, header login, unknown user, cookie flow.
# Runs a throwaway container bound to 127.0.0.1 and removes it afterwards.
#
# Usage: tests/n8n-hook/run.sh <n8n-image>
set -euo pipefail

IMAGE=${1:?usage: run.sh <n8n-image>}
HERE=$(cd "$(dirname "$0")" && pwd)
HOOK=${HOOK:-$HERE/../../roles/n8n/files/hooks.js}
PORT=${PORT:-5679}
NAME=n8n-hook-test-$$
VOL=$NAME-data
BASE=http://127.0.0.1:$PORT
OWNER=hook-test-owner@example.test
JAR=$(mktemp)
fail=0

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker volume rm "$VOL" >/dev/null 2>&1 || true
  rm -f "$JAR"
}
trap cleanup EXIT

check() { # name expected actual
  if [ "$2" = "$3" ]; then
    echo "PASS $1 ($3)"
  else
    echo "FAIL $1: expected $2, got $3"
    fail=1
  fi
}

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

echo "image: $IMAGE"
docker run -d --name "$NAME" -p "127.0.0.1:$PORT:5678" \
  -v "$VOL:/home/node/.n8n" \
  -v "$HOOK:/home/node/.n8n/hooks.js:ro" \
  -e N8N_ENCRYPTION_KEY="$(openssl rand -hex 32)" \
  -e N8N_DIAGNOSTICS_ENABLED=false \
  -e N8N_VERSION_NOTIFICATIONS_ENABLED=false \
  -e N8N_TEMPLATES_ENABLED=false \
  -e N8N_PERSONALIZATION_ENABLED=false \
  -e EXTERNAL_HOOK_FILES=/home/node/.n8n/hooks.js \
  -e N8N_TRUSTED_EMAIL_HEADER=x-auth-request-email \
  "$IMAGE" >/dev/null

# Wait for n8n to answer, then for the hook to register. /healthz answers before the
# n8n.ready hooks run, so the hook needs its own wait.
ready=0
for _ in $(seq 1 90); do
  if [ "$(code "$BASE/healthz")" = 200 ]; then ready=1; break; fi
  if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != true ]; then break; fi
  sleep 2
done
if [ "$ready" != 1 ]; then
  echo "FAIL n8n did not become ready"
  docker logs "$NAME" 2>&1 | tail -40
  exit 1
fi
hook_line=0
for _ in $(seq 1 30); do
  if docker logs "$NAME" 2>&1 | grep -qE "trusted-email-hook\] (active|disabled)"; then hook_line=1; break; fi
  sleep 1
done
if [ "$hook_line" != 1 ]; then
  echo "FAIL hook did not register (no 'trusted-email-hook] active' line within 30s)"
  docker logs "$NAME" 2>&1 | tail -20
  exit 1
fi

logs=$(docker logs "$NAME" 2>&1)
if grep -q "trusted-email-hook\] active" <<<"$logs"; then
  echo "PASS hook loaded (log line present)"
else
  echo "FAIL hook not active (no 'trusted-email-hook] active' log line)"
  fail=1
fi
if grep -qE "Spread syntax|TypeError|trusted-email-hook\] disabled" <<<"$logs"; then
  echo "FAIL errors in startup log:"
  grep -E "Spread syntax|TypeError|trusted-email-hook\] disabled" <<<"$logs" | head -5
  fail=1
fi

check "owner setup" 200 "$(code -X POST "$BASE/rest/owner/setup" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$OWNER\",\"firstName\":\"Hook\",\"lastName\":\"Test\",\"password\":\"HookTest-123456\"}")"

check "API without header is rejected" 401 "$(code "$BASE/rest/workflows")"
check "API with owner header is allowed" 200 "$(code -H "X-Auth-Request-Email: $OWNER" "$BASE/rest/workflows")"
check "API with unknown email is rejected" 401 \
  "$(code -H 'X-Auth-Request-Email: nobody@example.test' "$BASE/rest/workflows")"

# Cookie flow: the header on the first request issues n8n-auth; a later request works with the cookie only.
code -c "$JAR" -o /dev/null -H "X-Auth-Request-Email: $OWNER" "$BASE/" >/dev/null
if grep -q "n8n-auth" "$JAR"; then echo "PASS cookie issued (n8n-auth)"; else echo "FAIL no n8n-auth cookie issued"; fail=1; fi
check "API with cookie only is allowed" 200 "$(code -b "$JAR" "$BASE/rest/workflows")"

if [ "$fail" = 0 ]; then echo "ALL PASS: $IMAGE"; else echo "FAILURES: $IMAGE"; fi
exit "$fail"
