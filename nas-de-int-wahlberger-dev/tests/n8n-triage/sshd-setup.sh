#!/bin/sh
# Runs inside an alpine container (tests/n8n-triage/run.sh). Starts sshd with the
# n8n-diag account, the real forced command and stub systemd tools, so the workflow's
# SSH node talks to the same forced command the NAS runs.
set -eu
apk add --no-cache openssh-server bash >/dev/null
ssh-keygen -A >/dev/null
adduser -D -s /bin/bash -h /var/lib/n8n-diag n8n-diag
mkdir -p /etc/n8n-diag /var/lib/n8n-diag/.ssh
mkdir -p /usr/local/sbin
cp /diag/n8n-diag-bundle.sh /usr/local/sbin/n8n-diag-bundle
chmod 755 /usr/local/sbin/n8n-diag-bundle
printf 'caddy.service\nn8n.service\n' >/etc/n8n-diag/units
cat >/usr/local/bin/systemctl <<'STUB'
#!/bin/sh
echo "stub systemctl: $*"
echo "Active: active (running) since test"
STUB
cat >/usr/local/bin/journalctl <<'STUB'
#!/bin/sh
echo "stub journal: $*"
echo "stub log line"
STUB
chmod 755 /usr/local/bin/systemctl /usr/local/bin/journalctl
pubkey=$(cat /keys/n8n-diag.pub)
printf 'restrict,command="/usr/local/sbin/n8n-diag-bundle" %s\n' "$pubkey" >/var/lib/n8n-diag/.ssh/authorized_keys
chown -R n8n-diag:n8n-diag /var/lib/n8n-diag
chmod 700 /var/lib/n8n-diag/.ssh
chmod 600 /var/lib/n8n-diag/.ssh/authorized_keys
passwd -u n8n-diag >/dev/null 2>&1 || true
exec /usr/sbin/sshd -D -e
