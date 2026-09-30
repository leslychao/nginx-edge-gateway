#!/bin/sh
set -eu
# Uses isolated local resources. Never run against an existing local gateway.
export EDGE_ENV=local
. "$(dirname "$0")/../scripts/lib.sh"
docker volume inspect "$CONFIG_VOLUME" >/dev/null 2>&1 && fail 'Local test resources already exist; refusing to replace them.'
cleanup_tests() {
    test_status=$?
    trap - EXIT
    docker rm -f "$GATEWAY_NAME" "$GATEWAY_NAME-fixture" "$GATEWAY_NAME-operation-lock" >/dev/null 2>&1 || true
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
cp -R nginx/conf.d nginx/snippets "$test_config/"
for test_site in plain second ws secure wrong-name untrusted; do
    test_port=8080
    test_scheme=http
    [ "$test_site" != second ] || test_port=8090
    case "$test_site" in secure|wrong-name|untrusted) test_port=8443; test_scheme=https ;; esac
    {
        printf 'server { listen 80 proxy_protocol; server_name %s.example.com; location / {\n' "$test_site"
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
volume_command -c 'sed -i "$ d" /gateway/current/nginx.conf'
sh scripts/reload.sh
# Run the real deploy script with a clean, disposable Git checkout. The candidate
# parses, but its self-signed frontend fails the production trust check: rollback
# must restore the previous workers/configuration, not merely exit nonzero.
deployment_checkout=$(mktemp -d "$ROOT/.work/deployment.XXXXXX")
deployment_checkout=.work/${deployment_checkout##*/}
cp -R scripts deploy nginx sites .gitignore .gitattributes "$deployment_checkout/"
git -C "$deployment_checkout" init -q
git -C "$deployment_checkout" add .
git -C "$deployment_checkout" -c user.name=GatewayTest -c user.email=gateway-test@example.invalid commit -qm fixture
candidate_sha=$(git -C "$deployment_checkout" rev-parse HEAD)
if sh "$deployment_checkout/scripts/deploy.sh" "$candidate_sha"; then fail 'Untrusted frontend incorrectly passed deployment health check'; fi
verify_revision integration || fail 'Deployment rollback did not restore the prior loaded version'
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
