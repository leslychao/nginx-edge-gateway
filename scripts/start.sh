#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"
acquire_lock
validate_release current
start_gateway
release=$(active_release)
verify_revision "${release#releases/}" || fail 'Nginx started but did not serve the expected configuration revision.'
compose up -d --no-build renewal
