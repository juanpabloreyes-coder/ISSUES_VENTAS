"""ISSUES_VENTAS sin Power BI.

Uso (desde la carpeta ISSUES_VENTAS):
  python -m issues_sync run          # genera Data\\VENTAS_ISSUES.json y Dashboard\\Issues-Ventas-Report.html
  python -m issues_sync diagnostico  # igual, pero NO escribe nada: imprime conteos y avisos
  python -m issues_sync login        # UNA VEZ: inicia sesion en Autodesk (la API de Issues lo exige)
  python -m issues_sync refrescar    # renueva la sesion (lo hace la tarea diaria)

Credenciales: las mismas de PLANOS_VENTAS y PUBLICACIONES_VENTAS (APS_CLIENT_ID / APS_CLIENT_SECRET).
"""
import argparse
import json
import logging
import os
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path

from .aps import APS
from .issues import Documentos, construir
from .personas import Personas, leer_equipos
from .sesion import Sesion, SesionError

RAIZ = Path(__file__).resolve().parent.parent
FUENTE = "APS (ACC Issues)"
MARCADOR = '<script id="issues-data" type="application/json"></script>'


def _ruta(v):
    p = Path(v)
    return p if p.is_absolute() else RAIZ / p


def _log_automation(msg):
    try:
        with open(RAIZ / "Automation" / "issues_sync.log", "a", encoding="utf-8") as f:
            f.write(f"{datetime.now():%Y-%m-%d %H:%M:%S}  ISSUESSYNC  {msg}\n")
    except Exception:
        pass


def escribir(filas, avisos, cfg):
    if not filas:
        return "SIN ACTUALIZACION: no se obtuvo ningun issue. Se conservan el JSON y el HTML anteriores."
    json_path = _ruta(cfg.get("json", "Data/VENTAS_ISSUES.json"))
    html_path = _ruta(cfg.get("html", "Dashboard/Issues-Ventas-Report.html"))
    plantilla = _ruta(cfg.get("plantilla", "Dashboard/Issues-Ventas-Report.template.html"))

    try:
        prev = json.loads(json_path.read_text(encoding="utf-8-sig"))
        if (prev.get("source") == FUENTE and prev.get("rows") == filas and "avisos" not in prev
                and html_path.exists() and html_path.stat().st_mtime >= plantilla.stat().st_mtime):
            return f"SIN CAMBIOS: {len(filas)} issues. Se conservan el JSON y el HTML existentes."
    except Exception:
        pass

    # Los avisos (p.ej. nombres de personas fuera del listado) solo van a la terminal y al log,
    # nunca al JSON ni al dashboard.
    snapshot = {"generatedAt": datetime.now().astimezone().isoformat(), "source": FUENTE,
                "rowCount": len(filas), "rows": filas}
    txt = json.dumps(snapshot, ensure_ascii=False, indent=2)
    seguro = txt.replace("</script>", "<\\/script>")
    template = plantilla.read_text(encoding="utf-8").replace("__ISSUES_DATA_JSON__", "")
    bloque = f'<script id="issues-data" type="application/json">{seguro}</script>'
    if MARCADOR in template:
        html = template.replace(MARCADOR, bloque)
    elif "</body>" in template:
        html = template.replace("</body>", bloque + "</body>")
    else:
        raise ValueError("La plantilla HTML no tiene un punto para insertar los datos.")

    for destino, contenido in ((json_path, txt), (html_path, html)):
        destino.parent.mkdir(parents=True, exist_ok=True)
        tmp = destino.with_suffix(destino.suffix + ".tmp")
        tmp.write_text(contenido, encoding="utf-8")
        tmp.replace(destino)
    return f"EXPORTACION COMPLETADA: {len(filas)} issues."


def _credenciales():
    cid, sec = os.environ.get("APS_CLIENT_ID"), os.environ.get("APS_CLIENT_SECRET")
    if not cid or not sec:
        raise SystemExit("Falta APS_CLIENT_ID / APS_CLIENT_SECRET (las mismas variables que usa PLANOS_VENTAS).")
    return cid, sec


def _sesion(cfg):
    cid, sec = _credenciales()
    return Sesion(cid, sec, cfg.get("callback_url", "http://localhost:8765/callback"))


def procesar(cfg, escribir_salida=True):
    cid, sec = _credenciales()
    aps = APS(cid, sec)
    pid = cfg["aps"]["project_id"]

    aps.sesion = _sesion(cfg)
    logging.info("Leyendo usuarios, tipos e issues de ACC...")
    usuarios = aps.usuarios_proyecto(pid)
    tipos = aps.tipos_issue(pid)
    issues = aps.issues(pid)
    logging.info("ACC: %d issues, %d tipos, %d usuarios del proyecto", len(issues), len(tipos), len(usuarios))

    xlsx = _ruta(cfg["equipos_xlsx"])
    avisos = []
    if xlsx.exists():
        personas = Personas(leer_equipos(xlsx, cfg.get("equipos_hoja", "Integrantes")), cfg.get("alias_personas"))
    else:
        avisos.append(f"No se encontro el Excel de equipos: {xlsx}. Todos quedan SIN EQUIPO.")
        personas = Personas([], cfg.get("alias_personas"))

    docs = Documentos(aps, pid, cfg.get("raiz_nombres", ["Project Files"]), _ruta(cfg.get("cache", "cache/documentos.json")))
    filas, av = construir(issues, tipos, usuarios, docs, personas, cfg)
    docs.guardar()
    avisos += av

    print(f"Issues en ACC: {len(issues)}  ->  en el reporte (5D - GCP con archivo): {len(filas)}")
    print("Por estado:", dict(Counter(f["Status"] for f in filas)))
    print("Por proyecto:", dict(Counter(f["ProyectoConcurso"] or "(sin proyecto)" for f in filas)))
    print("Por equipo:", dict(Counter(f["Equipo"] for f in filas)))
    for a in avisos:
        print("AVISO:", a)

    if not escribir_salida:
        return "DIAGNOSTICO: no se escribio ningun archivo."
    return escribir(filas, avisos, cfg)


def main():
    ap = argparse.ArgumentParser(prog="issues_sync")
    ap.add_argument("cmd", choices=["run", "diagnostico", "login", "refrescar"])
    ap.add_argument("--config", default=str(RAIZ / "config.json"))
    a = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    cfg = json.loads(Path(a.config).read_text(encoding="utf-8"))
    if a.cmd in ("login", "refrescar"):
        try:
            s = _sesion(cfg)
            if a.cmd == "login":
                ruta = s.login()
                print(f"\nSesion iniciada y guardada en {ruta}")
            else:
                s.refrescar()
                print("Sesion renovada.")
        except SesionError as e:
            _log_automation(f"SESION: {e}")
            print(f"\nERROR: {e}", file=sys.stderr)
            sys.exit(3)
        return
    try:
        estado = procesar(cfg, escribir_salida=(a.cmd == "run"))
    except SystemExit:
        raise
    except Exception as e:
        _log_automation(f"ERROR: {e}. Se conservan el JSON y el HTML anteriores.")
        print(f"\nERROR: {e}\nSe conservan el JSON y el HTML anteriores.", file=sys.stderr)
        sys.exit(2)
    print("\n" + estado)
    if a.cmd == "run":
        _log_automation(estado)


if __name__ == "__main__":
    main()
