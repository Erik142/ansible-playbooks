#!/bin/sh
# Fetches this playbook's Ansible Vault password from 1Password instead of a
# plaintext .vault_pass file. Requires the 1Password CLI (`op`) signed in and
# the desktop app unlocked, local interactive runs only. The 1Password item
# name is set in exactly one place: here.
#
# PROPOSED item name, not yet created. Confirm before building the vault.
exec op read "op://DevOps/Ansible Vault - netcup-ci-wahlberger-dev/password" --no-newline
