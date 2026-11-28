#!/bin/sh
# Fetches the Ansible Vault password of the ci host (vault id `ci`) from 1Password.
# Needs the 1Password CLI signed in and the app unlocked; local runs only. Semaphore
# supplies its own password from its Key Store.
exec op read "op://DevOps/Ansible Vault - netcup-ci-wahlberger-dev/password" --no-newline
