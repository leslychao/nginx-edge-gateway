#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"
revision=${1:-$(git rev-parse HEAD)}
case "$revision" in *[!a-f0-9]*|'') fail 'Expected a full Git commit SHA' ;; esac
[ "${#revision}" -eq 40 ] || fail 'Expected a full Git commit SHA'
[ "$(git rev-parse HEAD)" = "$revision" ] || fail 'Checkout differs from deployment SHA'
[ -z "$(git status --porcelain --untracked-files=normal)" ] || fail 'Deployment requires a clean checkout.'
acquire_lock
previous=$(active_release)
if [ "$previous" = "releases/$revision" ]; then
    validate_release current
    start_gateway
    verify_revision "$revision" || fail 'Active release is not running.'
    sh scripts/check-routes.sh
    compose up -d --no-build renewal
    exit 0
fi
if running; then
    deployed_image=$(docker inspect --format '{{.Config.Image}}' "$GATEWAY_NAME")
    [ "$deployed_image" = "$NGINX_IMAGE" ] || fail 'Image changed: perform the documented controlled image upgrade first.'
fi
stage_release "$ROOT/nginx" "$revision"
rollback_on_exit() {
    deploy_status=$?
    trap - EXIT
    if [ "$deploy_status" -ne 0 ]; then
        printf '%s\n' 'Deployment failed; restoring previous release.' >&2
        if [ -n "$previous" ]; then
            if ! restore_release "$previous"; then
                printf '%s\n' 'ROLLBACK FAILED: the previous gateway deployment was not restored.' >&2
            fi
        else
            if ! compose stop gateway; then
                printf '%s\n' 'ROLLBACK FAILED: the first gateway deployment could not be stopped.' >&2
            fi
        fi
    fi
    if ! docker rm "$LOCK_ID" >/dev/null; then
        printf '%s\n' 'Could not release the gateway operation lock.' >&2
        [ "$deploy_status" -ne 0 ] || deploy_status=1
    fi
    exit "$deploy_status"
}
trap rollback_on_exit EXIT
previous_container=$(docker inspect --format '{{.Id}}' "$GATEWAY_NAME" 2>/dev/null || true)
activate_release "releases/$revision"
start_gateway
current_container=$(docker inspect --format '{{.Id}}' "$GATEWAY_NAME")
if [ "$current_container" = "$previous_container" ]; then reload_checked; fi
verify_revision "$revision" || fail 'New configuration revision was not applied.'
# Verify both the loaded revision and the application route before accepting it.
sh scripts/check-routes.sh
compose up -d --no-build renewal
printf 'Deployed %s\n' "$revision"
