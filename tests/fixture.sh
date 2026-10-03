#!/bin/sh
set -eu
exec python -u - <<'PY'
import base64
import datetime
import hashlib
import http.server
import json
import os
import socketserver
import ssl
import struct
import threading
from pathlib import Path
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

root = Path('/certificates')
root.mkdir(exist_ok=True)
now = datetime.datetime.now(datetime.timezone.utc)
key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'Gateway integration CA')])
ca = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
      .serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(minutes=5))
      .not_valid_after(now+datetime.timedelta(days=1)).add_extension(x509.BasicConstraints(ca=True, path_length=None), True)
      .sign(key, hashes.SHA256()))
(root/'ca.crt').write_bytes(ca.public_bytes(serialization.Encoding.PEM))
for domain in ['helmg.ru', 'backend.test']:
    target = root/'live'/domain
    target.mkdir(parents=True, exist_ok=True)
    leaf_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    leaf = (x509.CertificateBuilder().subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, domain)]))
            .issuer_name(name).public_key(leaf_key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now-datetime.timedelta(minutes=5)).not_valid_after(now+datetime.timedelta(days=1))
            .add_extension(x509.SubjectAlternativeName([x509.DNSName(domain)]), False)
            .sign(key, hashes.SHA256()))
    (target/'fullchain.pem').write_bytes(leaf.public_bytes(serialization.Encoding.PEM)+ca.public_bytes(serialization.Encoding.PEM))
    (target/'privkey.pem').write_bytes(leaf_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    os.chmod(target/'privkey.pem', 0o600)

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args):
        pass
    def do_GET(self):
        if self.headers.get('Upgrade', '').lower() == 'websocket':
            accept = base64.b64encode(hashlib.sha1((self.headers['Sec-WebSocket-Key']+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            self.send_response(101)
            self.send_header('Upgrade', 'websocket')
            self.send_header('Connection', 'Upgrade')
            self.send_header('Sec-WebSocket-Accept', accept)
            self.end_headers()
            header = self.rfile.read(2)
            length = header[1] & 127
            mask = self.rfile.read(4)
            data = bytes(value ^ mask[index % 4] for index, value in enumerate(self.rfile.read(length)))
            self.wfile.write(bytes([0x81, len(data)])+data)
            self.wfile.flush()
            self.close_connection = True
            return
        if self.path == '/large-cookie':
            self.send_response(302)
            self.send_header('Location', '/after-login')
            self.send_header('Set-Cookie', 'gateway-test=' + 'x' * 10240 + '; Path=/; HttpOnly; Secure; SameSite=Lax')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        response = json.dumps({'backend': self.server.server_port, 'headers': dict(self.headers)}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response)))
        self.end_headers()
        self.wfile.write(response)

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

for port in [8080, 8090, 8443]:
    server = Server(('0.0.0.0', port), Handler)
    if port == 8443:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(root/'live/backend.test/fullchain.pem', root/'live/backend.test/privkey.pem')
        context.set_servername_callback(lambda sock, name, ctx: setattr(sock, 'sni_name', name))
        server.socket = context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
class TurnTcp(socketserver.StreamRequestHandler):
    def handle(self):
        proxy = self.rfile.readline(108).decode().rstrip('\r\n')
        assert proxy.startswith('PROXY TCP4 '), proxy
        for payload in self.rfile:
            self.wfile.write((json.dumps({'proxy': proxy, 'payload': payload.decode().rstrip('\n')})+'\n').encode())
            self.wfile.flush()

class TurnUdp(socketserver.BaseRequestHandler):
    def handle(self):
        data, connection = self.request
        value = {'payload': data.decode(), 'upstreamPort': self.client_address[1]}
        connection.sendto(json.dumps(value).encode(), self.client_address)
        # TURN can send unsolicited channel data after the allocation response.
        threading.Timer(0.3, lambda: connection.sendto(json.dumps({**value, 'late': True}).encode(), self.client_address)).start()

for server in [socketserver.ThreadingTCPServer(('0.0.0.0', 5349), TurnTcp),
               socketserver.ThreadingUDPServer(('0.0.0.0', 3478), TurnUdp)]:
    threading.Thread(target=server.serve_forever, daemon=True).start()
(root/'ready').write_text('ready')
threading.Event().wait()
PY
