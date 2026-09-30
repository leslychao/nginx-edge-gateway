#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"
acquire_lock
compose stop renewal
running || exit 0
# QUIT on its own would trigger unless-stopped after the master exits.
docker update --restart=no "$GATEWAY_NAME" >/dev/null
docker exec "$GATEWAY_NAME" nginx -p /gateway/current/ -c nginx.conf -s quit
docker wait "$GATEWAY_NAME" >/dev/null
printf '%s\n' 'Nginx stopped gracefully. start.sh restores the Compose restart policy.'
