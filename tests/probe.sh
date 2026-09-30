#!/bin/sh
set -eu
exec python -u - <<'PY'
import http.client
import json
import socket
import ssl

def connect(tls=False, host='helmg.ru'):
    port = 443 if tls else 80
    sock = socket.create_connection(('127.0.0.1', port), timeout=5)
    if tls:
        sock = ssl.create_default_context(cafile='/certificates/ca.crt').wrap_socket(sock, server_hostname=host)
    return sock

def request(host, path='/', tls=False):
    with connect(tls, host) as sock:
        sock.sendall(f'GET {path} HTTP/1.1\r\nHost: {host}\r\nX-Real-IP: 1.2.3.4\r\nX-Forwarded-For: 5.6.7.8\r\nX-Forwarded-Proto: made-up\r\nConnection: close\r\n\r\n'.encode())
        response = http.client.HTTPResponse(sock)
        response.begin()
        return response.status, dict(response.getheaders()), response.read()

status, _, body = request('plain.example.com')
assert status == 200, (status, body)
plain = json.loads(body)
assert plain['backend'] == 8080
assert plain['headers']['Host'] == 'plain.example.com'
# Both address headers must come from the TCP peer, never from visitor headers.
assert plain['headers']['X-Real-IP'] == '127.0.0.1', plain
assert plain['headers']['X-Forwarded-Proto'] == 'http'
assert plain['headers']['X-Forwarded-For'] == '127.0.0.1', plain
assert json.loads(request('second.example.com')[2])['backend'] == 8090
assert request('unknown.invalid')[0] == 404
assert request('helmg.ru')[0] == 308
assert request('helmg.ru', '/.well-known/acme-challenge/probe')[2] == b'acme-ok'
assert request('helmg.ru', tls=True)[0] == 200
assert request('secure.example.com')[0] == 200
for host, tls in [('plain.example.com', False), ('secure.example.com', False), ('helmg.ru', True)]:
    status, headers, body = request(host, '/large-cookie', tls)
    assert status == 302, f'Large response cookie rejected for {host}: HTTP {status}'
    assert headers.get('Location') == '/after-login', f'Redirect changed for {host}'
    assert headers.get('Set-Cookie') == 'gateway-test=' + 'x' * 10240 + '; Path=/; HttpOnly; Secure; SameSite=Lax', f'Cookie changed for {host}'
    assert body == b'', f'Redirect body changed for {host}'
assert request('wrong-name.example.com')[0] == 502, 'Upstream certificate name verification is disabled'
assert request('untrusted.example.com')[0] == 502, 'Upstream CA verification is disabled'
try:
    connect(True, 'unknown.invalid')
except ssl.SSLError:
    pass
else:
    raise AssertionError('Unknown SNI was accepted')
with connect() as sock:
    sock.sendall(b'GET / HTTP/1.1\r\nHost: ws.example.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n')
    received = b''
    while b'\r\n\r\n' not in received:
        received += sock.recv(4096)
    assert b'101 Switching Protocols' in received, received
    mask = b'abcd'
    payload = b'echo'
    sock.sendall(b'\x81\x84'+mask+bytes(value ^ mask[i % 4] for i, value in enumerate(payload)))
    frame = b''
    while len(frame) < 6:
        frame += sock.recv(6-len(frame))
    assert frame == b'\x81\x04echo', frame
print('PASS: host routing, headers, 10 KiB response cookie, unknown Host/SNI, HTTP redirect, ACME, TLS frontend, verified TLS backend, WS echo')
PY
