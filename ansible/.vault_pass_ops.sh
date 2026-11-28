#!/bin/sh
# Fetches the Ansible Vault password of the ops host (vault id `ops`) from 1Password.
# Needs the 1Password CLI signed in and the app unlocked; local runs only. Semaphore
# supplies its own password from its Key Store.
exec op read "op://DevOps/Ansible Vault - ops-de-wahlberger-dev/password" --no-newline
