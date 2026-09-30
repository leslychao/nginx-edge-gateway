#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"
domain='' backend='' port='' scheme=http websocket=false
frontend_https=false certificate='' tls_name='' trusted_ca=/etc/ssl/certs/ca-certificates.crt force=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --force) force=true; shift; continue ;;
        --domain|--backend|--port|--backend-scheme|--websocket|--frontend-https|--certificate|--backend-tls-name|--backend-ca)
            [ "$#" -ge 2 ] || fail "Missing value for $1"
            case "$1" in
                --domain) domain=$2 ;; --backend) backend=$2 ;; --port) port=$2 ;;
                --backend-scheme) scheme=$2 ;; --websocket) websocket=$2 ;;
                --frontend-https) frontend_https=$2 ;; --certificate) certificate=$2 ;;
                --backend-tls-name) tls_name=$2 ;; --backend-ca) trusted_ca=$2 ;;
            esac
            shift 2 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done
valid_hostname() {
    [ -n "$1" ] && [ "${#1}" -le 253 ] && printf '%s\n' "$1" | awk -F . '
        { for (i=1; i<=NF; i++) if (length($i)<1 || length($i)>63 || $i !~ /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/) exit 1 }'
}
valid_hostname "$domain" || fail 'Domain must be a lowercase DNS hostname (no wildcard).'
valid_hostname "$backend" || fail 'Backend must be an IPv4 address or lowercase DNS hostname.'
case "$port" in ''|*[!0-9]*) fail 'Port must be 1..65535' ;; esac
[ "$port" -ge 1 ] && [ "$port" -le 65535 ] || fail 'Port must be 1..65535'
case "$scheme" in http|https) ;; *) fail 'Backend scheme must be http or https' ;; esac
case "$websocket:$frontend_https" in true:true|true:false|false:true|false:false) ;; *) fail 'Boolean options require true or false' ;; esac
if [ "$scheme" = https ]; then
    [ -n "$tls_name" ] || tls_name=$backend
    valid_hostname "$tls_name" || fail 'Invalid backend certificate name'
    case "$trusted_ca" in /certificates/*|/etc/ssl/certs/*) ;; *) fail 'CA must be mounted under /certificates or /etc/ssl/certs' ;; esac
    case "$trusted_ca" in *[!a-zA-Z0-9_./-]*|*..*) fail 'Invalid CA path' ;; esac
fi
if [ "$frontend_https" = true ]; then
    [ -n "$certificate" ] || certificate=$domain
    valid_hostname "$certificate" || fail 'Certificate must be an existing certificate directory name.'
fi
acquire_lock
target=$ROOT/nginx/conf.d/$domain.conf
[ ! -e "$target" ] || [ "$force" = true ] || fail 'Site already exists; use --force to replace it.'
mkdir -p .work
site_temp=$(mktemp -d "$ROOT/.work/site.XXXXXX")
if [ -e "$target" ]; then cp "$target" "$site_temp/previous.conf"; fi
site_committed=false
finish_site() {
    site_status=$?
    trap - EXIT
    if [ "$site_committed" != true ]; then
        if [ -f "$site_temp/previous.conf" ]; then cp "$site_temp/previous.conf" "$target"; else rm -f "$target"; fi
        printf '%s\n' 'Site validation failed. Previous file restored; no reload performed.' >&2
    fi
    rm -rf "$site_temp"
    docker rm "$LOCK_ID" >/dev/null
    exit "$site_status"
}
trap finish_site EXIT
export SITE_DOMAIN="$domain" SITE_BACKEND="$backend" SITE_PORT="$port" SITE_SCHEME="$scheme"
export SITE_WS="$websocket" SITE_HTTPS="$frontend_https" SITE_CERT="$certificate" SITE_TLS_NAME="$tls_name" SITE_CA="$trusted_ca"
awk '
    /@LISTEN@/ { gsub(/@LISTEN@/, ENVIRON["SITE_HTTPS"] == "true" ? "443 ssl proxy_protocol" : "80 proxy_protocol") }
    /@DOMAIN@/ { gsub(/@DOMAIN@/, ENVIRON["SITE_DOMAIN"]) }
    /@BACKEND_URL@/ { gsub(/@BACKEND_URL@/, ENVIRON["SITE_SCHEME"] "://" ENVIRON["SITE_BACKEND"] ":" ENVIRON["SITE_PORT"]) }
    /@TLS@/ {
        if (ENVIRON["SITE_HTTPS"] == "true") {
            print "    ssl_certificate /certificates/live/" ENVIRON["SITE_CERT"] "/fullchain.pem;"
            print "    ssl_certificate_key /certificates/live/" ENVIRON["SITE_CERT"] "/privkey.pem;"
            print "    include snippets/ssl-common.conf;"
        }
        next
    }
    /@WEBSOCKET@/ { if (ENVIRON["SITE_WS"] == "true") print "        include snippets/proxy-websocket.conf;"; next }
    /@BACKEND_TLS@/ {
        if (ENVIRON["SITE_SCHEME"] == "https") {
            print "        proxy_ssl_server_name on;"
            print "        proxy_ssl_verify on;"
            print "        proxy_ssl_verify_depth 3;"
            print "        proxy_ssl_name " ENVIRON["SITE_TLS_NAME"] ";"
            print "        proxy_ssl_trusted_certificate " ENVIRON["SITE_CA"] ";"
        }
        next
    }
    /@REDIRECT@/ {
        if (ENVIRON["SITE_HTTPS"] == "true") {
            print "server {\n    listen 80 proxy_protocol;\n    server_name " ENVIRON["SITE_DOMAIN"] ";"
            print "    location ^~ /.well-known/acme-challenge/ { root /var/www/acme; try_files $uri =404; }"
            print "    location / { return 308 https://" ENVIRON["SITE_DOMAIN"] "$request_uri; }\n}"
        }
        next
    }
    { print }
' sites/site.conf.template > "$target"
stage_release "$ROOT/nginx" "site-$(date -u +%Y%m%d%H%M%S)-$$"
site_committed=true
printf 'Created and validated %s. Commit and deploy to activate; no reload performed.\n' "$target"
