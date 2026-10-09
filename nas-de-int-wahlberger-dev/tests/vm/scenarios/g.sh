#!/usr/bin/env bash
# Ad-hoc: run a command in the guest as root. Usage: g.sh 'cmd'
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
gs "$@"
