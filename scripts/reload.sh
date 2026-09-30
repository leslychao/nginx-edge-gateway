#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"
acquire_lock
running || fail 'Gateway is not running.'
reload_checked
release=$(active_release)
verify_revision "${release#releases/}" || fail 'Reload did not apply the expected revision.'
