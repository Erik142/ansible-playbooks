#!/usr/bin/env bash
# Ad-hoc: source the helpers and eval the arguments, e.g. b.sh 'gs "uptime"'
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
eval "$*"
