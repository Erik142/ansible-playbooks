#!/bin/sh
# Fetches this playbook's Ansible Vault password from 1Password instead of a
# plaintext .vault_pass file. Requires the 1Password CLI (`op`) signed in
# and the desktop app unlocked (biometrics/Touch ID) — local interactive
# runs only. Semaphore's automated runs supply the vault password from its
# own Key Store instead; this script is never used there. See README.md.
exec op read "op://DevOps/Ansible Vault - rpi-boras/password" --no-newline
