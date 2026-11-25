# ssh_authorized_keys

Authorizes one or more SSH public keys for `ssh_authorized_keys_user` — your
personal key(s), for manual access, and Semaphore UI's dedicated automation
key (see the `pi-de-int-wahlberger-dev` playbook), for unattended
`ansible-playbook` runs.

## Role variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ssh_authorized_keys_user` | `erikwahlberger` | Unix account the keys are authorized for. |
| `ssh_authorized_keys_list` | `[]` (**required**) | List of public key lines to authorize. Not secret — lives in `vars.yml`, not Vault. A line may start with authorized_keys options, e.g. `from="10.0.0.0/24,1.2.3.4" ssh-ed25519 AAAA... comment`. |
| `ssh_authorized_keys_revoked` | `[]` | List of public key lines to remove (`state: absent`). |

## Options such as `from=`

Put the whole line, options included, into `ssh_authorized_keys_list`; no
separate `key_options` is used (spike A-26: the line is stored verbatim, a
changed option list updates the entry in place, a repeat reports 0 changed).
Do not mix both forms for one key.

## Revoking a key (BR-10)

To retire a key, move it from `ssh_authorized_keys_list` into
`ssh_authorized_keys_revoked` and run the role; it matches on key type and
body, so options and comment do not matter. **Keep the key in the revoked list
afterwards** (do not delete the entry once applied), so a later run on a host
that still has it removes it again. A key in both lists is an error: the role
fails before any change and names the key's comment. Removing a key from the
list alone does not delete it from the host (the role is not `exclusive`).

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
