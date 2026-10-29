#!/usr/bin/env python3
"""faux-ocis.py : simule un serveur oCIS pour les tests (migration, transferts oCIS -> NAS,
migration depuis le PC).

    python3 faux-ocis.py <port> <dossier des espaces> <rclone> [utilisateur] [mot de passe]

- /status.php, /graph/v1.0/me/drives (espace personnel + espaces projets : un sous-dossier
  du dossier des espaces par espace, cree s'il manque), /auth-app/tokens
- WebDAV : /dav/spaces/<id>/... transmis a « rclone serve webdav » (vrai WebDAV, dates de
  modification par l'en-tete X-OC-Mtime comme oCIS)
- authentification basique ; le fichier <dossier>/.refuser fait repondre 401 (jeton expire)
Arret : SIGTERM (rclone serve est arrete avec lui).
"""
import base64
import http.client
import urllib.parse
import http.server
import json
import os
import signal
import socket
import subprocess
import sys
import time

PORT = int(sys.argv[1])
RACINE = os.path.abspath(sys.argv[2])
RCLONE = sys.argv[3]
USER = sys.argv[4] if len(sys.argv) > 4 else "alice"
PASS = sys.argv[5] if len(sys.argv) > 5 else "secret"
EXTERNE = "https://cloud.exemple.fr"     # adresse publique renvoyee par oCIS (remplacee par le client)

ESPACES = [
    {"id": "personnel-alice", "driveType": "personal", "name": "Alice Martin", "owner": {"user": {"displayName": "Alice Martin"}}},
    {"id": "projet-docs", "driveType": "project", "name": "Documents partagés"},
    {"id": "projet-photos", "driveType": "project", "name": "Photos"},
]
for e in ESPACES:
    os.makedirs(os.path.join(RACINE, e["id"]), exist_ok=True)

s = socket.socket()
s.bind(("127.0.0.1", 0))
PORT_DAV = s.getsockname()[1]
s.close()
def lie_au_parent():  # rclone serve s'arrete avec ce programme, meme tue brutalement
    try:
        import ctypes
        ctypes.CDLL("libc.so.6").prctl(1, signal.SIGTERM)    # PR_SET_PDEATHSIG
    except Exception:
        pass


dav = subprocess.Popen([RCLONE, "serve", "webdav", RACINE, "--addr", "127.0.0.1:%d" % PORT_DAV, "--baseurl", "/dav/spaces",
                        "--config", "/dev/null", "--dir-cache-time", "0s", "-q"], stdin=subprocess.DEVNULL, preexec_fn=lie_au_parent)
for _ in range(100):
    try:
        socket.create_connection(("127.0.0.1", PORT_DAV), timeout=0.2).close()
        break
    except OSError:
        time.sleep(0.1)


def arret(*_):
    dav.terminate()
    sys.exit(0)


signal.signal(signal.SIGTERM, arret)
signal.signal(signal.SIGINT, arret)


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def autorise(self):
        if os.path.exists(os.path.join(RACINE, ".refuser")):
            return False
        a = self.headers.get("Authorization", "")
        if not a.startswith("Basic "):
            return False
        try:
            u, _, p = base64.b64decode(a[6:]).decode().partition(":")
        except Exception:
            return False
        return u == USER and p == PASS

    def repondre(self, code, corps=b"", entetes=None):
        self.send_response(code)
        for k, v in (entetes or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(corps)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(corps)

    def corps(self):
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            out = b""
            while True:
                n = int(self.rfile.readline().strip().split(b";")[0], 16)
                if n == 0:
                    self.rfile.readline()
                    return out
                out += self.rfile.read(n)
                self.rfile.readline()
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def traiter(self):
        chemin = self.path.split("?")[0]
        if chemin == "/status.php":
            return self.repondre(200, b'{"installed":true,"productname":"Infinite Scale"}', {"Content-Type": "application/json"})
        if not self.autorise():
            self.corps()
            return self.repondre(401, b"Unauthorized", {"WWW-Authenticate": 'Basic realm="ocis"'})
        if chemin == "/graph/v1.0/me/drives":
            v = []
            for e in ESPACES:
                d = dict(e)
                d["root"] = {"webDavUrl": "%s/dav/spaces/%s" % (EXTERNE, e["id"])}
                d["quota"] = {"total": 0, "remaining": 0} if e["driveType"] == "project" else {"total": 10 << 30, "remaining": 9 << 30}
                v.append(d)
            return self.repondre(200, json.dumps({"value": v}).encode(), {"Content-Type": "application/json"})
        if chemin == "/auth-app/tokens":
            return self.repondre(200, json.dumps([{"expiration_date": "2099-01-01T00:00:00Z"}]).encode(), {"Content-Type": "application/json"})
        if not chemin.startswith("/dav/spaces/"):
            return self.repondre(404, b"not found")
        # WebDAV : transmis a rclone serve webdav
        corps = self.corps()
        ent = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "authorization", "transfer-encoding", "content-length", "connection")}
        if "Destination" in ent:
            dst = ent["Destination"]
            i = dst.find("/dav/spaces/")
            ent["Destination"] = "http://127.0.0.1:%d%s" % (PORT_DAV, dst[i:] if i >= 0 else dst)
        ent["Content-Length"] = str(len(corps))
        c = http.client.HTTPConnection("127.0.0.1", PORT_DAV, timeout=600)
        c.request(self.command, self.path, body=corps, headers=ent)
        r = c.getresponse()
        data = r.read()
        hs = {k: v for k, v in r.getheaders() if k.lower() not in ("content-length", "transfer-encoding", "connection")}
        c.close()
        # date de modification envoyee par le client (comme oCIS : X-OC-Mtime)
        mt = self.headers.get("X-OC-Mtime")
        if self.command == "PUT" and mt and r.status < 300:
            f = os.path.join(RACINE, urllib.parse.unquote(chemin[len("/dav/spaces/"):]))
            try:
                os.utime(f, (float(mt), float(mt)))
                hs["X-OC-MTime"] = "accepted"
            except (OSError, ValueError):
                pass
        self.repondre(r.status, data, hs)

    def __getattr__(self, nom):
        if nom.startswith("do_"):
            return self.traiter
        raise AttributeError(nom)


srv = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H)
srv.daemon_threads = True
srv.handle_error = lambda *a: None       # clients qui ferment la connexion
try:
    srv.serve_forever()
finally:
    dav.terminate()
