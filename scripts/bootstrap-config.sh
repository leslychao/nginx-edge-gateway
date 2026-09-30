#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"
acquire_lock
[ -z "$(active_release)" ] || fail 'Bootstrap is only allowed before the first active release.'
mkdir -p .work/bootstrap
cp nginx/nginx.conf .work/bootstrap/
cp -R nginx/snippets .work/bootstrap/
mkdir -p .work/bootstrap/conf.d
cp nginx/conf.d/00-default.conf .work/bootstrap/conf.d/
cat > .work/bootstrap/conf.d/helmg.ru.conf <<'EOF'
server {
    listen 80 proxy_protocol;
    server_name helmg.ru;
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/acme;
        try_files $uri =404;
    }
    location / { return 503; }
}
EOF
revision=bootstrap-$(date -u +%Y%m%d%H%M%S)
stage_release "$ROOT/.work/bootstrap" "$revision"
activate_release "releases/$revision"
printf '%s\n' 'Bootstrap validated. start.sh only binds loopback 18080/18443; public ingress stays unchanged.'
