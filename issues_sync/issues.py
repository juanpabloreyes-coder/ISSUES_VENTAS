"""Tabla VENTAS_ISSUES sin Power BI (replica la consulta del modelo ISSUES_VENTAS).

Por cada issue de ACC:
  - Category / Type  = tipo / subtipo del issue (solo 5D - GCP y sus 4 subtipos, configurable).
  - Assigned to, Created by, Closed by = nombre del usuario (miembros del proyecto en ACC).
  - Placement / archivo = documento vinculado al issue (su nombre actual en Forma).
  - ProyectoConcurso = carpeta de primer nivel dentro de Project Files donde vive ese documento.
  - Disciplina = por palabras en el nombre del archivo (ARQ, EST, ELE, ESP, MEC, PLO).
  - Equipo = segun Excel de integrantes, por el nombre de "Assigned to".
Se excluyen issues sin archivo asociado (igual que en Power BI).
"""
import json
import logging
import re
from datetime import datetime, timezone
from pathlib import Path

from .aps import nombre_carpeta
from .personas import disciplina

log = logging.getLogger("issues_sync.issues")

# Etiquetas que reconoce el dashboard (OPEN / CLOSED en la plantilla). En Power BI 'pending' e
# 'in_review' salian como 'pending' / 'In review' y el dashboard no los contaba como abiertos.
ESTADOS = {"open": "Open", "closed": "Closed", "completed": "Completed", "draft": "Draft",
           "pending": "Pending", "in_review": "In Review", "in review": "In Review"}


def estado(s):
    t = str(s or "").strip()
    return ESTADOS.get(t.lower(), t.replace("_", " ").title() if t else None)


def fecha_o(texto):
    """'2026-08-28T00:42:56.753Z' -> '2026-08-28T00:42:56.7530000' (UTC, sin zona, como Power BI).
    '2026-08-27' -> '2026-08-27T00:00:00.0000000'."""
    if not texto:
        return None
    s = str(texto).strip()
    m = re.match(r"^(\d{4}-\d{2}-\d{2})(?:[T ](\d{2}:\d{2}(?::\d{2})?)(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?$", s)
    if not m:
        return s
    fecha, hora, frac, zona = m.groups()
    if not hora:
        return f"{fecha}T00:00:00.0000000"
    if len(hora) == 5:
        hora += ":00"
    dt = datetime.fromisoformat(f"{fecha}T{hora}" + (zona.replace("Z", "+00:00") if zona else "+00:00"))
    dt = dt.astimezone(timezone.utc)
    frac = (frac or ".0")[1:8].ljust(7, "0")
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + frac


def linaje(urn):
    """URN de version (fs.file:vf.X?version=N) o de linaje -> URN de linaje del archivo."""
    s = str(urn or "")
    if "fs.file:vf." in s:
        return "urn:adsk.wipprod:dm.lineage:" + s.split("fs.file:vf.", 1)[1].split("?", 1)[0]
    if "dm.lineage:" in s:
        return s.split("?", 1)[0]
    return None


class Documentos:
    """Nombre y ProyectoConcurso de cada archivo vinculado a un issue, con cache en disco."""

    def __init__(self, aps, project_id, raices, cache_path):
        self.aps, self.pid = aps, project_id
        self.raices = {r.strip().lower() for r in raices}
        self.p = Path(cache_path)
        try:
            self.cache = json.loads(self.p.read_text(encoding="utf-8"))
        except Exception:
            self.cache = {}
        self.carpetas = {}

    def _carpeta(self, fid):
        if fid not in self.carpetas:
            j = self.aps.carpeta(self.pid, fid)
            d = (j or {}).get("data") or {}
            parent = (((d.get("relationships") or {}).get("parent") or {}).get("data") or {}).get("id")
            self.carpetas[fid] = {"nombre": nombre_carpeta(d).strip(), "parent": parent} if d else None
        return self.carpetas[fid]

    def resolver(self, lin):
        """-> {nombre, proyecto} o None si el archivo ya no existe / no hay acceso."""
        if lin in self.cache:
            return self.cache[lin]
        self.consultados = getattr(self, "consultados", 0) + 1
        if self.consultados % 10 == 1:
            log.info("  Buscando en Forma el archivo de los issues (%d)...", self.consultados)
        j = self.aps.item(self.pid, lin)
        d = (j or {}).get("data")
        if not d:
            return None
        nombre = (d.get("attributes") or {}).get("displayName")
        fid = (((d.get("relationships") or {}).get("parent") or {}).get("data") or {}).get("id")
        cadena, vistos = [], set()
        while fid and fid not in vistos:
            vistos.add(fid)
            c = self._carpeta(fid)
            if not c:
                break
            if c["nombre"].lower() in self.raices:
                break
            cadena.append(c["nombre"])
            fid = c["parent"]
        proyecto = cadena[-1] if cadena else None   # la carpeta justo debajo de Project Files
        info = {"nombre": nombre, "proyecto": proyecto}
        self.cache[lin] = info
        return info

    def guardar(self):
        self.p.parent.mkdir(parents=True, exist_ok=True)
        self.p.write_text(json.dumps(self.cache, ensure_ascii=False), encoding="utf-8")


def construir(issues, tipos, usuarios, docs, personas, cfg):
    """-> (filas, avisos) con las mismas columnas que exportaba Power BI."""
    tipo_por_id, subtipo_por_id = {}, {}
    for t in tipos:
        tipo_por_id[t.get("id")] = t.get("title")
        for st in t.get("subtypes") or []:
            subtipo_por_id[st.get("id")] = st.get("title")

    nombre_usuario = {}
    for u in usuarios:
        for k in (u.get("autodeskId"), u.get("id")):
            if k:
                nombre_usuario[k] = u.get("name")

    def usuario(uid):
        if not uid:
            return None
        return nombre_usuario.get(uid) or "Usuario no encontrado"

    categoria = cfg.get("categoria", "5D - GCP")
    subtipos = set(cfg.get("subtipos", ["5D - Especificación", "5D - Omisión", "5D - Modelado", "5D - Parametrización"]))
    filas, sin_archivo, archivos_no_encontrados = [], 0, set()
    # Solo cuentan los asignados que estan en el Excel de integrantes (cualquier equipo).
    solo_listado = cfg.get("solo_integrantes_listado", True)
    fuera_listado = {}

    for it in issues:
        if it.get("deletedAt"):
            continue
        cat = tipo_por_id.get(it.get("issueTypeId"))
        sub = subtipo_por_id.get(it.get("issueSubtypeId"))
        if cat != categoria or sub not in subtipos:
            continue

        nombre_archivo, proyecto = None, None
        for ld in it.get("linkedDocuments") or []:
            lin = linaje(ld.get("urn"))
            info = docs.resolver(lin) if lin else None
            if info:
                nombre_archivo, proyecto = info.get("nombre"), info.get("proyecto")
            else:
                if lin:
                    archivos_no_encontrados.add(lin)
                vw = ((ld.get("details") or {}).get("viewable") or {}).get("name")
                nombre_archivo = nombre_archivo or vw
            if nombre_archivo:
                break
        if not nombre_archivo:
            sin_archivo += 1
            continue

        asignado = usuario(it.get("assignedTo"))
        _, equipo = personas.resolver(asignado) if asignado else (None, "SIN EQUIPO")
        if solo_listado and equipo == "SIN EQUIPO":
            fuera_listado[asignado or "(sin asignar)"] = fuera_listado.get(asignado or "(sin asignar)", 0) + 1
            continue
        filas.append({
            "ID": f"VENTAS{it['displayId']}" if it.get("displayId") is not None else None,
            "Title": it.get("title"),
            "Status": estado(it.get("status")),
            "Category": cat,
            "Type": sub,
            "Description": it.get("description"),
            "Assigned to": asignado,
            "Created by": usuario(it.get("createdBy")),
            "Created on": fecha_o(it.get("createdAt")),
            "Due date": fecha_o(it.get("dueDate")),
            "Updated on": fecha_o(it.get("updatedAt")),
            "Closed by": usuario(it.get("closedBy")),
            "Closed at": fecha_o(it.get("closedAt")),
            "Disciplina": disciplina(nombre_archivo),
            "Proyecto": cfg.get("proyecto_acc", "VENTAS GCP"),
            "Equipo": equipo,
            "ProyectoConcurso": proyecto,
        })

    filas.sort(key=lambda f: f["Created on"] or "", reverse=True)
    avisos = []
    if sin_archivo:
        avisos.append(f"{sin_archivo} issues de {categoria} sin archivo asociado (excluidos, igual que en Power BI).")
    if archivos_no_encontrados:
        avisos.append(f"{len(archivos_no_encontrados)} archivos vinculados a issues no se encontraron en Forma "
                      f"(borrados o sin acceso); se uso el nombre guardado en el issue y quedan sin ProyectoConcurso.")
    if fuera_listado:
        avisos.append("Issues excluidos porque el asignado no esta en el Excel de integrantes: " +
                      ", ".join(f"{n} ({c})" for n, c in sorted(fuera_listado.items())))
    sin_proy = sum(1 for f in filas if not f["ProyectoConcurso"])
    if sin_proy:
        avisos.append(f"{sin_proy} issues sin ProyectoConcurso identificado.")
    return filas, avisos
