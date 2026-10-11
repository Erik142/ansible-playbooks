#!/usr/bin/env bash
# Build a 'bare' snapshot = the 'clean' snapshot minus every package the roles
# install themselves, so the first `--check --diff` runs on a genuinely fresh
# host (units of those packages do not exist, check mode only simulates the
# install). Catches "Could not find the requested service" gaps that a fixture
# image with preinstalled packages hides.
#   ./make-bare.sh            roll back to 'clean', zypper rm, snapshot as 'bare'
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
HERE="$(dirname "${BASH_SOURCE[0]}")"

# Keep in sync with the zypper tasks of the roles (podman, firewall, security,
# notify_failure, restic_backup). sqlite3 stays: the DB stand-in of s00 needs it.
BARE_PACKAGES=(podman podman-docker firewalld fail2ban rebootmgr snapper snapper-zypp-plugin jq restic)

"$HERE/reset.sh" clean
# Remove only what is installed ('clean' may already lack some of them).
vm_ssh "pk=\$(rpm -q --qf '%{NAME}\\n' ${BARE_PACKAGES[*]} | grep -v 'is not installed' || true); \
  sudo -n systemctl disable --now firewalld fail2ban rebootmgr podman.socket 2>/dev/null || true; \
  [ -z \"\$pk\" ] || sudo -n zypper --non-interactive rm \$pk"
left="$(vm_ssh "rpm -q ${BARE_PACKAGES[*]} | grep -vc 'is not installed'" || true)"
[[ "$left" == 0 ]] || { echo "packages still installed after rm" >&2; exit 1; }
"$HERE/snapshot.sh" bare
echo ">> 'bare' snapshot ready; use scenarios/s05-fresh-check.sh"
