#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"
revision=${1:?Usage: rollback.sh RELEASE_ID}
case "$revision" in ''|*[!a-zA-Z0-9_-]*) fail 'Invalid release ID' ;; esac
acquire_lock
validate_release "releases/$revision"
activate_release "releases/$revision"
reload_checked
verify_revision "$revision" || fail 'Rollback revision was not applied.'
