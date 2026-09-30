#!/bin/sh
# Shared Docker transport, release validation and operation lock. This file is
# sourced by entry points; it must not change external state on its own.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
EDGE_ENV=${EDGE_ENV:-local}
case "$EDGE_ENV" in local|dev) ;; *) echo 'EDGE_ENV must be local or dev' >&2; exit 2 ;; esac
set -a
case "$EDGE_ENV" in
    local) . ./deploy/.env.local ;;
    dev) . ./deploy/.env.dev ;;
esac
. ./deploy/images.env
set +a
if [ "$EDGE_ENV" = dev ] && [ "$DOCKER_HOST" = tcp://192.168.0.107:2375 ]; then
    unset DOCKER_TLS_VERIFY DOCKER_TLS DOCKER_CERT_PATH
fi
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

fail() { printf '%s\n' "$*" >&2; exit 1; }
compose() {
    docker compose --project-name "$GATEWAY_NAME" --env-file "deploy/.env.$EDGE_ENV" \
        --env-file deploy/images.env -f deploy/compose.yaml "$@"
}
volume_command() {
    docker run --rm -i --network none --mount "type=volume,src=$CONFIG_VOLUME,dst=/gateway" \
        --entrypoint sh "$NGINX_IMAGE" "$@"
}
acquire_lock() {
    LOCK_ID=$(docker create --name "$GATEWAY_NAME-operation-lock" \
        --label nginx-edge.operation="$(basename "$0")" --network none \
        --entrypoint sh "$NGINX_IMAGE" -c 'exit 0') || \
        fail 'Gateway operation is locked. Check the owner; never remove a live operation lock.'
    trap 'docker rm "$LOCK_ID" >/dev/null' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}
running() {
    [ "$(docker inspect --format '{{.State.Running}}' "$GATEWAY_NAME" 2>/dev/null)" = true ]
}
start_gateway() {
    compose up -d --no-build gateway
    # Compose labels may be unchanged after stop.sh disabled the runtime policy.
    docker update --restart=unless-stopped "$GATEWAY_NAME" >/dev/null
}
validate_release() {
    validation_network=$BACKEND_NETWORK
    if running; then validation_network=container:$GATEWAY_NAME; fi
    docker run --rm --network "$validation_network" \
        --mount "type=volume,src=$CONFIG_VOLUME,dst=/gateway,readonly" \
        --mount "type=volume,src=$CERT_VOLUME,dst=/certificates,readonly" \
        --mount "type=volume,src=$ACME_VOLUME,dst=/var/www/acme,readonly" \
        --entrypoint nginx "$NGINX_IMAGE" -p "/gateway/$1/" -c nginx.conf -t
}
active_release() { volume_command -c 'readlink /gateway/current || true'; }
activate_release() {
    volume_command -c "ln -s \"\$1\" /gateway/current.next && mv -Tf /gateway/current.next /gateway/current" sh "$1"
}
reload_checked() {
    docker exec "$GATEWAY_NAME" nginx -p /gateway/current/ -c nginx.conf -t || \
        fail 'Invalid configuration: reload was NOT executed.'
    docker exec "$GATEWAY_NAME" nginx -p /gateway/current/ -c nginx.conf -s reload
}
verify_revision() {
    revision_attempt=0
    while [ "$revision_attempt" -lt 15 ]; do
        actual_revision=$(docker exec "$GATEWAY_NAME" wget -q -T 2 -O - \
            http://127.0.0.1:8081/__gateway_revision 2>/dev/null) || actual_revision=''
        if [ "$actual_revision" = "$1" ]; then return 0; fi
        revision_attempt=$((revision_attempt + 1))
        sleep 1
    done
    return 1
}
stage_release() {
    release_source=$1
    release_id=$2
    case "$release_id" in ''|*[!a-zA-Z0-9_-]*) fail 'Invalid release ID' ;; esac
    [ -f "$release_source/nginx.conf" ] || fail 'Missing nginx.conf'
    mkdir -p .work
    release_temp=$(mktemp -d "$ROOT/.work/stage.XXXXXX")
    cp "$release_source/nginx.conf" "$release_temp/"
    cp -R "$release_source/conf.d" "$release_source/snippets" "$release_temp/"
    mkdir "$release_temp/automation"
    cp -R "$ROOT/scripts" "$ROOT/deploy" "$release_temp/automation/"
    mkdir "$release_temp/runtime"
    cat > "$release_temp/runtime/revision.conf" <<EOF
server {
    listen 127.0.0.1:8081;
    server_name localhost;
    access_log off;
    location = /__gateway_revision {
        default_type text/plain;
        return 200 "$release_id\n";
    }
}
EOF
    tar -C "$release_temp" -cf "$release_temp.tar" .
    if ! volume_command -c "$(cat <<'STAGE'
set -eu
candidate=/gateway/staging-$1
release=/gateway/releases/$1
mkdir -p /gateway/releases
test ! -e "$candidate"
mkdir "$candidate"
trap 'rm -rf "$candidate"' EXIT
tar -xf - -C "$candidate"
if [ -d "$release" ]; then
    diff -r "$release" "$candidate"
else
    mv "$candidate" "$release"
fi
STAGE
)" sh "$release_id" < "$release_temp.tar"; then
        rm -rf "$release_temp" "$release_temp.tar"
        fail 'Could not stage release (an existing release must have identical contents).'
    fi
    rm -rf "$release_temp" "$release_temp.tar"
    validate_release "releases/$release_id"
}
