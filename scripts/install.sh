#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"
for dependency in docker tar git; do
    command -v "$dependency" >/dev/null || fail "Missing dependency: $dependency"
done
docker info --format '{{.Name}} / {{.OSType}}'
docker compose version
docker image inspect "$NGINX_IMAGE" >/dev/null 2>&1 || docker pull "$NGINX_IMAGE"
docker image inspect "$CERTBOT_IMAGE" >/dev/null 2>&1 || docker pull "$CERTBOT_IMAGE"
for gateway_volume in "$CONFIG_VOLUME" "$CERT_VOLUME" "$ACME_VOLUME"; do
    docker volume inspect "$gateway_volume" >/dev/null 2>&1 || docker volume create "$gateway_volume"
done
docker network inspect "$BACKEND_NETWORK" >/dev/null 2>&1 || \
    docker network create --internal --subnet "$BACKEND_SUBNET" "$BACKEND_NETWORK"
docker network inspect "$TRANSPORT_NETWORK" >/dev/null 2>&1 || \
    docker network create --subnet "$TRANSPORT_SUBNET" --gateway "$TRANSPORT_GATEWAY" "$TRANSPORT_NETWORK"
actual_gateway=$(docker network inspect --format '{{(index .IPAM.Config 0).Gateway}}' "$TRANSPORT_NETWORK")
[ "$actual_gateway" = "$TRANSPORT_GATEWAY" ] || fail 'Transport network gateway differs from trusted PROXY sender.'
compose config --quiet
printf '%s\n' 'Prepared Docker volumes/networks. No Windows service, Firewall or public ports were changed.'
