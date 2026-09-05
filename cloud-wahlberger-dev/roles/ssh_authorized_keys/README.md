# ssh_authorized_keys

Authorizes one or more SSH public keys for `ssh_authorized_keys_user` — your
personal key(s), for manual access, and Semaphore UI's dedicated automation
key (see the `pi-de-int-wahlberger-dev` playbook), for unattended
`ansible-playbook` runs.

## Role variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ssh_authorized_keys_user` | `erikwahlberger` | Unix account the keys are authorized for. |
| `ssh_authorized_keys_list` | `[]` (**required**) | List of public key lines to authorize. Not secret — lives in `vars.yml`, not Vault. |

## Why one key per purpose, not one shared key

Your personal key and Semaphore's automation key are deliberately separate.
If Semaphore's key ever needs revoking (compromised instance,
decommissioning it), you can pull just that one entry without touching your
own daily-use access, and auth logs can tell the two apart.

Duplicated verbatim across `cloud-wahlberger-dev`,
`nas-de-int-wahlberger-dev`, and `pi-de-int-wahlberger-dev` rather than
extracted into a shared role — see those playbooks' top-level READMEs for
why (short version: at this scale, duplication keeps every playbook fully
self-contained; extraction is the right move once/if that duplication starts
actually hurting).
