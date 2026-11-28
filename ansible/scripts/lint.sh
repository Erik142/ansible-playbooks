#!/bin/sh
# Lint and syntax-check the homelab collection. Used locally and by the CI lint job.
#
# Never touches 1Password: ansible.cfg loads every vault_identity_list script at
# startup, so a plain `ansible-lint` would call `op` four times per run. The env
# overrides below replace the vault config for this process tree only.
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"

dummy=$(mktemp)
trap 'rm -f "$dummy"' EXIT
echo "ci-cannot-decrypt-this-is-expected" > "$dummy"
export ANSIBLE_VAULT_PASSWORD_FILE="$dummy"
# One dummy identity, not an empty list: an empty entry makes Ansible read the repo
# root as a password file.
export ANSIBLE_VAULT_IDENTITY_LIST="lint@$dummy"

if [ ! -d collections/ansible_collections/wahlberger/homelab ]; then
	ansible-galaxy collection install -r requirements.yml -p collections --force
fi

yamllint -s collections/homelab
ansible-lint collections/homelab

# Every role has a molecule scenario or a recorded exclusion (see coverage.yml).
python3 collections/homelab/extensions/molecule/check_coverage.py

for playbook in collections/homelab/playbooks/*.yml; do
	host=$(basename "$playbook" .yml)
	ansible-playbook "$playbook" -i "inventories/$host/hosts.yml" --syntax-check >/dev/null
	echo "syntax ok: $playbook"
done
