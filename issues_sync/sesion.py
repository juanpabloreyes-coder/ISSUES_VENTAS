"""Sesion de usuario (OAuth de 3 patas) para la API de Issues de ACC.

La API de Issues no acepta la autenticacion de la app sola (2 patas), ni siquiera actuando a
nombre de un usuario: exige que un usuario inicie sesion. Flujo:

  1. `python -m issues_sync login` (una sola vez): abre el navegador, inicias sesion en Autodesk,
     y se guarda la sesion en %LOCALAPPDATA%\\issues_sync\\sesion.json (fuera del proyecto y de git).
  2. Cada corrida usa esa sesion y la renueva (refresh token). La tarea diaria llama a
     `python -m issues_sync refrescar` para que no caduque aunque el reporte sea mensual.
  3. Si pasan mas de ~15 dias sin renovarse, hay que volver a hacer `login`.

Requisito en https://aps.autodesk.com/myapps : la app debe permitir OAuth de 3 patas
(tipo "Traditional Web App") y tener registrada la Callback URL de `config.json`
(por defecto http://localhost:8765/callback).
"""
import json
import os
import secrets
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlparse

import requests

BASE = "https://developer.api.autodesk.com"
ARCHIVO = Path(os.environ.get("LOCALAPPDATA") or Path.home()) / "issues_sync" / "sesion.json"


class SesionError(RuntimeError):
    pass


class Sesion:
    def __init__(self, client_id, client_secret, callback, scope="data:read"):
        self.cid, self.secret, self.callback, self.scope = client_id, client_secret, callback, scope

    # -- almacenamiento -------------------------------------------------
    def _leer(self):
        try:
            return json.loads(ARCHIVO.read_text(encoding="utf-8"))
        except Exception:
            return None

    def _guardar(self, j):
        datos = {"access_token": j["access_token"], "refresh_token": j.get("refresh_token"),
                 "expira": time.time() + int(j.get("expires_in", 3000)), "renovada": time.time()}
        ARCHIVO.parent.mkdir(parents=True, exist_ok=True)
        ARCHIVO.write_text(json.dumps(datos), encoding="utf-8")
        return datos

    def _pedir_token(self, data):
        r = requests.post(f"{BASE}/authentication/v2/token", auth=(self.cid, self.secret), data=data, timeout=60)
        if r.status_code != 200:
            try:
                det = r.json().get("error_description") or r.json().get("developerMessage") or r.text[:200]
            except Exception:
                det = r.text[:200]
            raise SesionError(f"Autodesk rechazo la sesion ({r.status_code}): {det}")
        return self._guardar(r.json())

    # -- uso normal -----------------------------------------------------
    def token(self):
        d = self._leer()
        if not d or not d.get("refresh_token"):
            raise SesionError("No hay sesion iniciada. Corre una vez:  python -m issues_sync login")
        if time.time() < d.get("expira", 0) - 120:
            return d["access_token"]
        return self.refrescar()["access_token"]

    def refrescar(self):
        d = self._leer()
        if not d or not d.get("refresh_token"):
            raise SesionError("No hay sesion iniciada. Corre una vez:  python -m issues_sync login")
        try:
            return self._pedir_token({"grant_type": "refresh_token", "refresh_token": d["refresh_token"],
                                      "scope": self.scope})
        except SesionError as e:
            raise SesionError(f"{e}. La sesion caduco: vuelve a correr  python -m issues_sync login")

    # -- login inicial --------------------------------------------------
    def login(self, espera_seg=300):
        u = urlparse(self.callback)
        puerto, ruta = u.port or 80, u.path or "/"
        estado = secrets.token_urlsafe(16)
        recibido = {}

        class Handler(BaseHTTPRequestHandler):
            def do_GET(h):
                q = urlparse(h.path)
                if q.path != ruta:
                    h.send_response(404); h.end_headers(); return
                p = parse_qs(q.query)
                recibido["code"] = (p.get("code") or [None])[0]
                recibido["state"] = (p.get("state") or [None])[0]
                recibido["error"] = (p.get("error_description") or p.get("error") or [None])[0]
                ok = recibido["code"] and recibido["state"] == estado
                h.send_response(200)
                h.send_header("Content-Type", "text/html; charset=utf-8")
                h.end_headers()
                msg = ("Listo. Ya puedes cerrar esta ventana y volver a la terminal." if ok
                       else f"No se pudo iniciar sesion: {recibido['error'] or 'respuesta invalida'}")
                h.wfile.write(f"<html><body style='font-family:sans-serif;padding:40px'><h2>{msg}</h2></body></html>".encode("utf-8"))

            def log_message(h, *a):
                pass

        srv = HTTPServer(("127.0.0.1", puerto), Handler)
        hilo = threading.Thread(target=srv.serve_forever, daemon=True)
        hilo.start()
        url = f"{BASE}/authentication/v2/authorize?" + urlencode({
            "response_type": "code", "client_id": self.cid, "redirect_uri": self.callback,
            "scope": self.scope, "state": estado})
        print("Se abrira el navegador para iniciar sesion en Autodesk.")
        print("Si no se abre, copia esta direccion en el navegador:\n" + url + "\n")
        webbrowser.open(url)
        t0 = time.time()
        while "code" not in recibido and "error" not in recibido and time.time() - t0 < espera_seg:
            time.sleep(0.5)
        srv.shutdown()
        if not recibido.get("code") or recibido.get("state") != estado:
            raise SesionError(f"No se completo el inicio de sesion: {recibido.get('error') or 'tiempo agotado'}")
        self._pedir_token({"grant_type": "authorization_code", "code": recibido["code"],
                           "redirect_uri": self.callback})
        return ARCHIVO
