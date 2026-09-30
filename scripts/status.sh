#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"
docker ps -a --filter "name=^/$GATEWAY_NAME$" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
docker ps -a --filter "name=^/$GATEWAY_NAME-renewal$" --format 'table {{.Names}}\t{{.Status}}'
if running; then
    docker top "$GATEWAY_NAME"
    docker exec "$GATEWAY_NAME" wget -q -O - http://127.0.0.1:8081/__gateway_revision
fi
printf 'Access/error logs: docker logs %s (rotated: 5 x 10 MiB)\n' "$GATEWAY_NAME"
printf 'Config: %s; certificates: %s; ACME: %s\n' "$CONFIG_VOLUME" "$CERT_VOLUME" "$ACME_VOLUME"
case "$(uname -s)" in
    MINGW*|MSYS*)
        printf '%s\n' 'The following Windows status is LOCAL: run on .107 for the server state.'
        netstat.exe -ano -p tcp | awk '$2 ~ /:(80|443)$/ { print }'
        ;;
esac
