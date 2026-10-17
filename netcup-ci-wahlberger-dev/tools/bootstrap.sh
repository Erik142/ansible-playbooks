#!/usr/bin/env bash
# Bootstrap the netcup CI host step by step. Operator-run, interactive.
#
# Does: 1Password vault item (if missing), netcup vault.yml (if missing, Resend
# key copied from the ops vault without printing it), host SSH check, check-mode
# runs, then one apply per stage with a pause before each. Never prints secrets.
#
# Usage: tools/bootstrap.sh [--skip-vault] [--stage N]
#   --stage N  start at stage N (1-5)
set -euo pipefail

# ansible-core 2.16 lives in this venv (pyenv shims do not resolve it).
ANSIBLE_BIN_DIR="${ANSIBLE_BIN_DIR:-$HOME/.pyenv/versions/3.10.13/envs/ansible-bind9-venv/bin}"
export PATH="$ANSIBLE_BIN_DIR:$PATH"

HOST_IP="152.53.18.9"
OPS_DIR="$(cd "$(dirname "$0")/../../ops-de-wahlberger-dev" && pwd)"
ITEM_TITLE="Ansible Vault - netcup-ci-wahlberger-dev"
VAULT_FILE="inventories/production/group_vars/all/vault.yml"
INVENTORY="inventories/production/hosts.yml"
START_STAGE=1
SKIP_VAULT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-vault) SKIP_VAULT=1 ;;
    --stage) START_STAGE="$2"; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

cd "$(dirname "$0")/.."

say() { printf '\n== %s\n' "$*"; }
pause() {
  read -r -p "Press Enter to continue (Ctrl-C to stop)... " _
}
run_playbook() {
  ansible-playbook -i "$INVENTORY" site.yml -e "ansible_host=$HOST_IP" "$@"
}

tmp_plain=""
cleanup() { [ -n "$tmp_plain" ] && rm -f "$tmp_plain"; return 0; }
trap cleanup EXIT

# --- Stage 1: vault ----------------------------------------------------------
if [ "$SKIP_VAULT" -eq 0 ] && [ "$START_STAGE" -le 1 ]; then
  say "Stage 1: vault password in 1Password"
  if op item get "$ITEM_TITLE" --vault DevOps >/dev/null 2>&1; then
    echo "1Password item exists, leaving it alone."
  else
    op item create --category=password --vault=DevOps \
      --title="$ITEM_TITLE" --generate-password=64 >/dev/null
    echo "Created 1Password item '$ITEM_TITLE' (password generated)."
  fi

  say "Stage 1: netcup vault.yml"
  if [ -f "$VAULT_FILE" ]; then
    echo "$VAULT_FILE exists, leaving it alone."
  else
    # Resend key from the ops vault: passed through a pipe, never printed.
    resend_key="$(ansible-vault view "$OPS_DIR/$VAULT_FILE" \
      --vault-password-file "$OPS_DIR/.vault_pass.sh" \
      | sed -n 's/^vault_notify_failure_resend_api_key: *"\(.*\)"$/\1/p')"
    if [ -z "$resend_key" ]; then
      echo "Resend key not found in the ops vault. Stopping." >&2
      exit 1
    fi
    tmp_plain="$(mktemp)"
    chmod 600 "$tmp_plain"
    cat > "$tmp_plain" <<EOF
vault_notify_failure_resend_api_key: "$resend_key"
vault_forgejo_runner_registration_token: ""
vault_beszel_agent_hub_key: ""
EOF
    unset resend_key
    ansible-vault encrypt "$tmp_plain" --output "$VAULT_FILE" \
      --vault-password-file .vault_pass.sh --encrypt-vault-id default
    echo "Wrote encrypted $VAULT_FILE."
  fi
fi

# --- Stage 2: host SSH check --------------------------------------------------
if [ "$START_STAGE" -le 2 ]; then
  say "Stage 2: personal key on the host"
  keys="$(ssh -o BatchMode=yes "erikwahlberger@$HOST_IP" 'wc -l < ~/.ssh/authorized_keys')"
  echo "authorized_keys lines on host: $keys"
  if [ "$keys" -lt 1 ]; then
    echo "No keys on host. Stopping before security is applied." >&2
    exit 1
  fi
  pause
fi

# --- Stage 3: check mode for everything pending -----------------------------
if [ "$START_STAGE" -le 3 ]; then
  say "Stage 3: check mode (changes nothing)"
  run_playbook --check --diff \
    --tags ssh_authorized_keys,notify_failure,security,firewall,common
  pause
fi

# --- Stage 4: apply, one role group at a time ---------------------------------
if [ "$START_STAGE" -le 4 ]; then
  say "Stage 4a: ssh_authorized_keys, notify_failure"
  run_playbook --tags ssh_authorized_keys,notify_failure
  pause
  say "Stage 4b: security (keep a second SSH session open)"
  run_playbook --tags security
  pause
  say "Stage 4c: firewall, common (common does a full zypper upgrade)"
  run_playbook --tags firewall,common
fi

# --- Stage 5: firewalld reload (may drop SSH) ---------------------------------
if [ "$START_STAGE" -le 5 ]; then
  say "Stage 5: ZeroTier firewall zone goes live after a firewalld reload"
  echo "A reload can drop SSH sessions. Open a second session before continuing."
  read -r -p "Reload firewalld now? [y/N] " answer
  if [ "$answer" = "y" ]; then
    ssh "erikwahlberger@$HOST_IP" 'sudo firewall-cmd --reload && sudo firewall-cmd --get-active-zones'
  else
    echo "Skipped. Run later: ssh erikwahlberger@$HOST_IP 'sudo firewall-cmd --reload'"
  fi
fi

say "Done"
