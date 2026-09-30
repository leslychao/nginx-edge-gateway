#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"
# Test routing, certificate trust and responses in the gateway network namespace.
# Public DNS/NAT reachability must additionally be checked from outside the LAN.
docker run --rm -i --network "container:$GATEWAY_NAME" --entrypoint python "$CERTBOT_IMAGE" - <<'PY'
import socket
import ssl

def request(host, port, path, tls=False):
    sock = socket.create_connection(('127.0.0.1', port), timeout=10)
    if tls:
        sock = ssl.create_default_context().wrap_socket(sock, server_hostname=host)
    with sock:
        sock.sendall(f'GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n'.encode())
        return sock.recv(4096).split(b'\r\n', 1)[0]

assert b' 404 ' in request('unknown.invalid', 80, '/'), 'Unknown Host was accepted'
assert b' 308 ' in request('helmg.ru', 80, '/'), 'HTTPS redirect missing'
assert b' 200 ' in request('helmg.ru', 443, '/.well-known/oauth-protected-resource/mcp', True), 'Helmglass metadata unavailable'
print('HTTP, TLS and Helmglass metadata route checks passed')
PY
