#!/bin/sh
set -eu
# Uses isolated local resources. Never run against an existing local gateway.
export EDGE_ENV=local
. "$(dirname "$0")/../scripts/lib.sh"
docker volume inspect "$CONFIG_VOLUME" >/dev/null 2>&1 && fail 'Local test resources already exist; refusing to replace them.'
cleanup_tests() {
    test_status=$?
    trap - EXIT
    docker rm -f "$GATEWAY_NAME" "$GATEWAY_NAME-renewal" "$GATEWAY_NAME-fixture" "$GATEWAY_NAME-operation-lock" >/dev/null 2>&1 || true
    docker volume rm "$CONFIG_VOLUME" "$CERT_VOLUME" "$ACME_VOLUME" "$GATEWAY_NAME-fixtures" >/dev/null 2>&1 || true
    docker network rm "$BACKEND_NETWORK" "$TRANSPORT_NETWORK" >/dev/null 2>&1 || true
    exit "$test_status"
}
trap cleanup_tests EXIT
sh scripts/install.sh
docker volume create "$GATEWAY_NAME-fixtures" >/dev/null
mkdir -p .work
tar -cf .work/fixtures.tar tests
docker run --rm -i --mount "type=volume,src=$GATEWAY_NAME-fixtures,dst=/fixtures" \
    --entrypoint tar "$NGINX_IMAGE" -xf - -C /fixtures < .work/fixtures.tar
docker run -d --name "$GATEWAY_NAME-fixture" --network "$BACKEND_NETWORK" --ip 172.30.243.3 --network-alias helmglass-edge \
    --mount "type=volume,src=$GATEWAY_NAME-fixtures,dst=/fixtures,readonly" \
    --mount "type=volume,src=$CERT_VOLUME,dst=/certificates" \
    --entrypoint sh "$CERTBOT_IMAGE" /fixtures/tests/fixture.sh >/dev/null
test_attempt=0
until docker exec "$GATEWAY_NAME-fixture" test -f /certificates/ready; do
    test_attempt=$((test_attempt + 1)); [ "$test_attempt" -lt 30 ] || fail 'TLS fixture failed to start'; sleep 1
done
test_config=$(mktemp -d "$ROOT/.work/integration.XXXXXX")
cp nginx/nginx.conf "$test_config/"
cp -R nginx/conf.d nginx/snippets nginx/stream.d "$test_config/"
for test_site in plain second ws secure wrong-name untrusted; do
    test_port=8080
    test_scheme=http
    [ "$test_site" != second ] || test_port=8090
    case "$test_site" in secure|wrong-name|untrusted) test_port=8443; test_scheme=https ;; esac
    {
        printf 'server { listen 80; server_name %s.example.com; location / {\n' "$test_site"
        printf 'include snippets/proxy-common.conf;\n'
        [ "$test_site" != ws ] || printf 'include snippets/proxy-websocket.conf;\n'
        if [ "$test_scheme" = https ]; then
            test_name=backend.test
            test_ca=/certificates/ca.crt
            [ "$test_site" != wrong-name ] || test_name=wrong.example.com
            [ "$test_site" != untrusted ] || test_ca=/etc/ssl/certs/ca-certificates.crt
            printf 'proxy_ssl_verify on; proxy_ssl_server_name on; proxy_ssl_name %s; proxy_ssl_trusted_certificate %s;\n' "$test_name" "$test_ca"
        fi
        printf 'proxy_pass %s://helmglass-edge:%s; } }\n' "$test_scheme" "$test_port"
    } > "$test_config/conf.d/$test_site.conf"
done
acquire_lock
trap cleanup_tests EXIT
stage_release "$test_config" integration
activate_release releases/integration
docker rm "$LOCK_ID" >/dev/null
trap cleanup_tests EXIT
sh scripts/start.sh
renewal_attempt=0
until docker exec "$GATEWAY_NAME-renewal" test -f /tmp/renewal-success; do
    renewal_attempt=$((renewal_attempt + 1))
    [ "$renewal_attempt" -lt 60 ] || fail 'Scheduled Docker renewal did not complete its first run'
    sleep 1
done
docker exec "$GATEWAY_NAME-renewal" test ! -f /tmp/renewal-failed || fail 'Scheduled renewal failed'
docker logs "$GATEWAY_NAME-renewal"
docker run --rm --mount "type=volume,src=$ACME_VOLUME,dst=/acme" --entrypoint sh "$NGINX_IMAGE" \
    -c 'mkdir -p /acme/.well-known/acme-challenge; printf acme-ok > /acme/.well-known/acme-challenge/probe'
docker run --rm --network "container:$GATEWAY_NAME" \
    --mount "type=volume,src=$GATEWAY_NAME-fixtures,dst=/fixtures,readonly" \
    --mount "type=volume,src=$CERT_VOLUME,dst=/certificates,readonly" \
    --entrypoint sh "$CERTBOT_IMAGE" /fixtures/tests/probe.sh
printf 'not_an_nginx_directive;\n' >> "$test_config/nginx.conf"
if sh scripts/test-config.sh "$test_config"; then fail 'Invalid candidate incorrectly passed nginx -t'; fi
verify_revision integration || fail 'Invalid candidate disrupted the active configuration'
# Corrupt only the disposable active test release and check the actual reload path.
volume_command -c 'printf "invalid_directive;\n" >> /gateway/current/nginx.conf'
if sh scripts/reload.sh; then fail 'Invalid active configuration incorrectly reloaded'; fi
verify_revision integration || fail 'Failed reload stopped the previous workers'
volume_command -c 'touch /gateway/certificate-reload-pending'
if sh scripts/certificates.sh renew; then fail 'Certificate operation ignored an invalid reload'; fi
volume_command -c 'test -f /gateway/certificate-reload-pending' || fail 'Failed certificate reload lost its retry marker'
volume_command -c 'sed -i "$ d" /gateway/current/nginx.conf'
sh scripts/certificates.sh renew
volume_command -c 'test ! -f /gateway/certificate-reload-pending' || fail 'Certificate reload did not clear its retry marker'
verify_revision integration || fail 'Certificate retry failed to preserve the configuration'
# Run the real deploy script with a clean, disposable Git checkout. The candidate
# parses, but its self-signed frontend fails the production trust check: rollback
# must restore the previous workers/configuration, not merely exit nonzero.
deployment_checkout=$(mktemp -d "$ROOT/.work/deployment.XXXXXX")
deployment_checkout=.work/${deployment_checkout##*/}
cp -R scripts deploy nginx sites .gitignore .gitattributes "$deployment_checkout/"
# The candidate changes a published port; its intentional trust failure must also
# restore the old Docker binding, not only the previous Nginx workers.
sed -i 's/127.0.0.1:25349/127.0.0.1:25350/' "$deployment_checkout/deploy/.env.local"
git -C "$deployment_checkout" init -q
git -C "$deployment_checkout" add .
git -C "$deployment_checkout" -c user.name=GatewayTest -c user.email=gateway-test@example.invalid commit -qm fixture
candidate_sha=$(git -C "$deployment_checkout" rev-parse HEAD)
# Make the saved deployment fail to restore after the candidate fails validation.
# Only this disposable release is changed; a real failure must still clean its
# temporary files and operation lock, preserving the original deployment status.
volume_command -c 'printf "\nstart_gateway() { return 71; }\n" >> /gateway/releases/integration/automation/scripts/lib.sh'
failed_restore_status=0
sh "$deployment_checkout/scripts/deploy.sh" "$candidate_sha" || failed_restore_status=$?
[ "$failed_restore_status" = 1 ] || fail 'Failed rollback replaced the original deploy exit code'
if docker inspect "$GATEWAY_NAME-operation-lock" >/dev/null 2>&1; then fail 'Failed rollback left the operation lock'; fi
[ -z "$(find "$deployment_checkout/.work" -maxdepth 1 -type d -name 'restore.*' -print)" ] || fail 'Failed rollback left temporary files'
candidate_turn_port=$(docker inspect --format '{{range index .HostConfig.PortBindings "5349/tcp"}}{{.HostPort}}{{end}}' "$GATEWAY_NAME")
[ "$candidate_turn_port" = 25350 ] || fail 'Candidate did not apply its TURN TLS Docker port'
volume_command -c 'sed -i "$ d" /gateway/releases/integration/automation/scripts/lib.sh'
sh scripts/rollback.sh integration
verify_revision integration || fail 'Manual rollback did not restore the prior loaded version'
manual_turn_port=$(docker inspect --format '{{range index .HostConfig.PortBindings "5349/tcp"}}{{.HostPort}}{{end}}' "$GATEWAY_NAME")
[ "$manual_turn_port" = 25349 ] || fail 'Manual rollback did not restore the TURN TLS Docker port'
if sh "$deployment_checkout/scripts/deploy.sh" "$candidate_sha"; then fail 'Untrusted frontend incorrectly passed deployment health check'; fi
verify_revision integration || fail 'Deployment rollback did not restore the prior loaded version'
restored_turn_port=$(docker inspect --format '{{range index .HostConfig.PortBindings "5349/tcp"}}{{.HostPort}}{{end}}' "$GATEWAY_NAME")
[ "$restored_turn_port" = 25349 ] || fail 'Deployment rollback did not restore the TURN TLS Docker port'
if sh "$deployment_checkout/scripts/deploy.sh" "$candidate_sha"; then fail 'Retry accepted an untrusted frontend'; fi
verify_revision integration || fail 'Retry with identical immutable release did not roll back'
sh "$deployment_checkout/scripts/add-site.sh" --domain sample.example.com --backend helmglass-edge --port 8080
original_site=$(git hash-object "$deployment_checkout/nginx/conf.d/sample.example.com.conf")
if sh "$deployment_checkout/scripts/add-site.sh" --domain sample.example.com --backend helmglass-edge --port 8090; then fail 'Existing site overwritten without --force'; fi
if sh "$deployment_checkout/scripts/add-site.sh" --domain sample.example.com --backend helmglass-edge --port 8443 --backend-scheme https --backend-ca /certificates/missing-ca.pem --force; then fail 'Missing CA was accepted'; fi
[ "$original_site" = "$(git hash-object "$deployment_checkout/nginx/conf.d/sample.example.com.conf")" ] || fail 'add-site did not restore the previous file'
verify_revision integration || fail 'add-site disrupted the live release'
sh scripts/stop.sh
sh scripts/start.sh
verify_revision integration || fail 'Restart lost the active revision'
[ "$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$GATEWAY_NAME")" = unless-stopped ] || fail 'Start did not restore restart policy'
printf '%s\n' 'PASS: invalid candidate/reload preserve workers; failed deploy rolls back; add-site restores file; graceful stop/start preserves configuration/certificates'
rm -rf "$test_config" "$deployment_checkout"
