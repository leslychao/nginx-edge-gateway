#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"
acquire_lock
if [ "${1:-}" = --active ]; then
    validate_release current
else
    stage_release "${1:-$ROOT/nginx}" "test-$(date -u +%Y%m%d%H%M%S)-$$"
fi
