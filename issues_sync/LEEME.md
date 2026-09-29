# issues_sync: ISSUES_VENTAS sin Power BI

Genera el mismo `Data\VENTAS_ISSUES.json` y `Dashboard\Issues-Ventas-Report.html` que
`Export-VENTAS_ISSUES.ps1`, leyendo directamente de ACC con las APIs de Autodesk (APS):

```
ACC Issues API           -> issues, tipos y subtipos
ACC Admin API            -> nombres de los usuarios del proyecto
Data Management (Forma)  -> nombre actual y ProyectoConcurso del archivo vinculado a cada issue
Equipos e integrantes - VENTAS.xlsx -> equipo del asignado
```

Ya no hacen falta DimProyectoConcurso, DimArchivoLocal ni sus monitores.

## Requisitos
- Python con `requests` y `openpyxl` (los mismos de PLANOS_VENTAS).
- Variables de entorno `APS_CLIENT_ID` / `APS_CLIENT_SECRET` (las mismas de PLANOS_VENTAS).

## Sesion de usuario (una sola vez)
La API de Issues de ACC exige que un usuario inicie sesion (no acepta la app sola). Una vez:
```
python -m issues_sync login
```
Se abre el navegador, inicias sesion en Autodesk y la sesion queda guardada en
`%LOCALAPPDATA%\issues_sync\sesion.json` (fuera del proyecto y de git). La tarea diaria la renueva
(`python -m issues_sync refrescar`); solo hay que repetir `login` si pasan ~15 dias sin renovarse.
En https://aps.autodesk.com/myapps la app debe tener la Callback URL `http://localhost:8765/callback`.

## Uso (desde la carpeta ISSUES_VENTAS)
```
python -m issues_sync diagnostico   # no escribe nada: muestra conteos y avisos
python -m issues_sync run           # genera JSON + HTML (o doble clic en Generar-Reporte-ISSUES.cmd)
```

## Reglas (iguales a la consulta VENTAS_ISSUES de Power BI)
- Solo issues de la categoria `5D - GCP` con subtipo Especificacion, Omision, Modelado o Parametrizacion
  (`categoria` y `subtipos` en `config.json`). Se excluyen los eliminados y los que no tienen archivo.
- ProyectoConcurso = carpeta de primer nivel dentro de Project Files donde vive el archivo del issue.
- Disciplina por palabras en el nombre del archivo (ARQ, EST, ELE, ESP, MEC, PLO).
- Equipo = segun el Excel, por el nombre de "Assigned to" (misma logica que PUBLICACIONES).
  Solo aparecen issues asignados a personas del Excel (`solo_integrantes_listado`); los demas salen como AVISO.
- Fechas en UTC, como las exportaba Power BI.

## Diferencias con Power BI
- Los estados `pending` e `in_review` salen como `Pending` e `In Review`, que son las etiquetas que el
  dashboard reconoce como abiertas (antes salian `pending` / `In review` y no se contaban).
- Nombre y proyecto del archivo se consultan a Forma y se guardan en `cache\documentos.json`.
