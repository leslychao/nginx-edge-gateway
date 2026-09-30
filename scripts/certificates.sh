#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"
operation=${1:?Usage: certificates.sh issue DOMAIN EMAIL | renew | dry-run}
case "$operation" in issue|renew|dry-run) ;; *) fail 'Unknown certificate operation' ;; esac
if [ "$operation" = issue ]; then
    domain=${2:?Missing domain}
    email=${3:?Missing ACME contact email}
    case "$domain" in ''|*[!a-z0-9.-]*|.*|*..*) fail 'Invalid domain' ;; esac
    case "$email" in *@*.*) ;; *) fail 'Invalid contact email' ;; esac
fi
acquire_lock
before=$(docker run --rm --network none --mount "type=volume,src=$CERT_VOLUME,dst=/certificates,readonly" \
    --entrypoint sh "$NGINX_IMAGE" -c 'find /certificates/live -name fullchain.pem -exec sha256sum {} \; 2>/dev/null | sort')
set -- --non-interactive --config-dir /certificates --work-dir /tmp/certbot-work --logs-dir /tmp/certbot-logs
case "$operation" in
    issue) set -- certonly "$@" --agree-tos --email "$email" --webroot -w /var/www/acme --cert-name "$domain" -d "$domain" ;;
    renew) set -- renew "$@" ;;
    dry-run) set -- renew "$@" --dry-run ;;
esac
docker run --rm --network "$TRANSPORT_NETWORK" \
    --mount "type=volume,src=$CERT_VOLUME,dst=/certificates" \
    --mount "type=volume,src=$ACME_VOLUME,dst=/var/www/acme" "$CERTBOT_IMAGE" "$@"
after=$(docker run --rm --network none --mount "type=volume,src=$CERT_VOLUME,dst=/certificates,readonly" \
    --entrypoint sh "$NGINX_IMAGE" -c 'find /certificates/live -name fullchain.pem -exec sha256sum {} \; 2>/dev/null | sort')
if [ "$before" != "$after" ] && running; then reload_checked; fi
