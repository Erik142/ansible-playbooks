#!/usr/bin/env python3
"""Tiny HTTPS server for BD-AC-90: serves /srv/fakekey/ on 127.0.0.1:8443 with a
throwaway self-signed certificate (installed into the guest's trust store)."""
import http.server
import ssl

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain("/srv/fakekey/c.pem", "/srv/fakekey/k.pem")
handler = lambda *a, **k: http.server.SimpleHTTPRequestHandler(*a, directory="/srv/fakekey", **k)  # noqa: E731
srv = http.server.HTTPServer(("127.0.0.1", 8443), handler)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
