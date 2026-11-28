#!/bin/sh
# Fetches the Ansible Vault password of the edge host (vault id `edge`) from 1Password.
# Needs the 1Password CLI signed in and the app unlocked; local runs only.
exec op read "op://DevOps/Ansible Vault - edge-de-wahlberger-dev/password" --no-newline
