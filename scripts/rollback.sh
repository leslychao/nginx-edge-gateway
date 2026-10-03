#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"
revision=${1:?Usage: rollback.sh RELEASE_ID}
case "$revision" in ''|*[!a-zA-Z0-9_-]*) fail 'Invalid release ID' ;; esac
acquire_lock
restore_release "releases/$revision" || fail 'Rollback deployment was not restored.'
