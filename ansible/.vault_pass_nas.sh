#!/bin/sh
# Fetches the Ansible Vault password of the NAS host (unlabelled vault files) from 1Password.
# Needs the 1Password CLI signed in and the app unlocked; local runs only.
exec op read "op://DevOps/Ansible Vault - nas-de-int-wahlberger-dev/password" --no-newline
