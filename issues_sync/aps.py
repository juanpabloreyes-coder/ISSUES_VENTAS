"""Cliente minimo de APS para ISSUES_VENTAS: Issues de ACC, usuarios del proyecto y archivos de Forma.

Misma autenticacion que PLANOS_VENTAS y PUBLICACIONES_VENTAS: 2-legged, credenciales en las
variables de entorno APS_CLIENT_ID / APS_CLIENT_SECRET, app registrada como Custom Integration.
"""
import logging
import time
from urllib.parse import quote

import requests

BASE = "https://developer.api.autodesk.com"
log = logging.getLogger("issues_sync.aps")


class APSError(RuntimeError):
    pass


class APS:
    def __init__(self, client_id, client_secret, scope="data:read account:read"):
        self.cid, self.secret, self.scope = client_id, client_secret, scope
        self._tok, self._exp = None, 0
        self.s = requests.Session()
        # La API de Issues no acepta la autenticacion de la app sola (2 patas), ni actuando a nombre
        # de un usuario: exige sesion de usuario (3 patas). Ver sesion.py.
        self.sesion = None

    def token(self):
        if self._tok and time.time() < self._exp - 60:
            return self._tok
        r = requests.post(f"{BASE}/authentication/v2/token", auth=(self.cid, self.secret),
                          data={"grant_type": "client_credentials", "scope": self.scope}, timeout=60)
        if r.status_code != 200:
            raise APSError(f"Autenticacion APS fallo ({r.status_code}): {r.text[:300]}")
        j = r.json()
        self._tok, self._exp = j["access_token"], time.time() + int(j.get("expires_in", 3000))
        return self._tok

    def get(self, url, ok=(200,), retries=5, como_usuario=False):
        if url.startswith("/"):
            url = BASE + url
        if como_usuario and not self.sesion:
            raise APSError("Falta la sesion de usuario para la API de Issues (python -m issues_sync login).")
        for i in range(retries):
            h = {"Authorization": f"Bearer {self.sesion.token() if como_usuario else self.token()}"}
            log.debug("GET %s", url)
            r = self.s.get(url, headers=h, timeout=(15, 60))
            if r.status_code in ok:
                return r.json() if r.status_code == 200 else None
            if r.status_code in (429, 500, 502, 503, 504):
                espera = min(2 ** i * 2, 30)
                log.info("  Autodesk respondio %s en %s; reintento %d/%d en %ds",
                         r.status_code, url.split("?")[0].split("/")[-1], i + 1, retries, espera)
                time.sleep(espera)
                continue
            raise APSError(f"GET {url.split('?')[0]} -> {r.status_code}: {_error_legible(r)}")
        raise APSError(f"GET {url}: demasiados reintentos")

    @staticmethod
    def sin_b(guid):
        return guid[2:] if guid.startswith("b.") else guid

    @staticmethod
    def con_b(guid):
        return guid if guid.startswith("b.") else "b." + guid

    def _paginado(self, url, limite=100, como_usuario=False, etiqueta="", max_paginas=200):
        """APIs de construction/* (results + pagination limit/offset)."""
        offset, out, primeros = 0, [], set()
        sep = "&" if "?" in url else "?"
        for pagina in range(1, max_paginas + 1):
            j = self.get(f"{url}{sep}limit={limite}&offset={offset}", como_usuario=como_usuario)
            res = j.get("results", [])
            total = (j.get("pagination") or {}).get("totalResults")
            clave = str((res[0] or {}).get("id")) if res else None
            if clave and clave in primeros:
                log.warning("  %s: la API repitio una pagina; se detiene la paginacion", etiqueta)
                return out
            primeros.add(clave)
            out.extend(res)
            offset += len(res)
            log.info("  %s: %d%s", etiqueta, len(out), f" de {total}" if total is not None else "")
            if not res or (total is not None and offset >= total) or len(res) < limite:
                return out
        log.warning("  %s: se alcanzo el limite de %d paginas", etiqueta, max_paginas)
        return out

    # -- Issues ---------------------------------------------------------
    def tipos_issue(self, project_id):
        """[{id, title, subtypes:[{id, title}]}]"""
        return self._paginado(f"/construction/issues/v1/projects/{self.sin_b(project_id)}/issue-types?include=subtypes", 200, True, "Tipos de issue")

    def issues(self, project_id):
        """Todos los issues no eliminados del proyecto."""
        return self._paginado(f"/construction/issues/v1/projects/{self.sin_b(project_id)}/issues", 100, True, "Issues")

    def usuarios_proyecto(self, project_id):
        """[{id, autodeskId, name, email, ...}] miembros del proyecto."""
        return self._paginado(f"/construction/admin/v1/projects/{self.sin_b(project_id)}/users", 200, False, "Usuarios del proyecto")

    # -- Data Management ------------------------------------------------
    def item(self, project_id, item_id):
        """Item (archivo) por su URN de linaje, o None si no existe/no hay acceso."""
        return self.get(f"/data/v1/projects/{self.con_b(project_id)}/items/{quote(item_id, safe='')}", ok=(200, 403, 404))

    def carpeta(self, project_id, folder_id):
        return self.get(f"/data/v1/projects/{self.con_b(project_id)}/folders/{quote(folder_id, safe='')}", ok=(200, 403, 404))


def _error_legible(r):
    """Mensaje de error de la API sin repetir el token de acceso."""
    try:
        j = r.json()
        partes = [str(j.get(k)) for k in ("title", "detail", "details", "developerMessage", "message") if j.get(k)]
        if partes:
            return " - ".join(partes)[:300]
    except Exception:
        pass
    return r.text[:200]


def nombre_carpeta(d):
    """Nombre ACTUAL de una carpeta: 'name' (displayName puede conservar el nombre anterior)."""
    a = (d or {}).get("attributes", {})
    return a.get("name") or a.get("displayName") or ""
