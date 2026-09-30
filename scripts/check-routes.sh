#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"
# The probe sends PROXY v1 itself inside the network namespace. It tests routing,
# certificate trust and response codes, NOT the native Windows source-IP path.
docker run --rm -i --network "container:$GATEWAY_NAME" --entrypoint python "$CERTBOT_IMAGE" - <<'PY'
import socket
import ssl

def request(host, port, path, tls=False):
    sock = socket.create_connection(('127.0.0.1', port), timeout=10)
    sock.sendall(f'PROXY TCP4 198.51.100.10 127.0.0.1 12345 {port}\r\n'.encode())
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
