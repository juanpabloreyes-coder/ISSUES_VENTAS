AUTOMATIZACIÓN DE PROYECTOCONCURSO Y DIMARCHIVOLOCAL

Ubicación activa del repositorio:
C:\Users\Usuario\DC\ACCDocs\GCPEASA\GCP_TRANSFORMACIÓN_DIGITAL\Project Files\01_IMPLEMENTACIÓN_BIM\0112_SQDCM\011211_VENTAS\ISSUES_VENTAS

El monitor revisa la jerarquía y los archivos de VENTAS GCP:
- inmediatamente al iniciar Windows;
- al detectar creación, eliminación, movimiento o cambio de nombre;
- al cerrar el PBIP si había una actualización pendiente;
- una vez cada hora como comprobación de seguridad.

Actualiza dos tablas del modelo:
- DimProyectoConcurso: vincula cada documento con la segunda carpeta bajo Project Files.
- DimArchivoLocal: vincula el URN de cada archivo de Desktop Connector con su nombre y ProyectoConcurso.

Muestra notificaciones al iniciar y terminar una actualización. Al abrir ISSUES_VENTAS.pbip,
muestra la fecha y hora de la última actualización del mapa.

Archivos:
- Update-ProyectoConcurso.ps1: actualiza y valida DimProyectoConcurso.
- Update-DimArchivoLocal.ps1: actualiza y valida DimArchivoLocal.
- Monitor-ProyectoConcurso.ps1: monitor continuo de carpetas y archivos.
- Start-ProyectoConcurso-Monitor.cmd: inicio manual.
- Activar-Notificaciones.cmd: reinicia el monitor en la sesión interactiva y muestra una prueba.
- Stop-ProyectoConcurso-Monitor.ps1: detiene el monitor.
- state.json: estado de DimProyectoConcurso.
- filemap-state.json: estado de DimArchivoLocal.
- automation.log: historial técnico.

Requisitos:
- Autodesk Desktop Connector debe estar sincronizado.
- Power BI debe estar cerrado para modificar los mapas.
- El monitor se inicia al iniciar sesión en Windows.

Importante:
- Un archivo nuevo normalmente obtiene URN cuando Desktop Connector termina de sincronizarlo.
- Si aún no tiene URN, se omitirá temporalmente y se incorporará en una revisión posterior.
- Actualizar DimArchivoLocal no sustituye la actualización de la extracción de Forma en Power BI.

Estructura del proyecto PBIP:
- ISSUES_VENTAS.pbip
- ISSUES_VENTAS.Report
- ISSUES_VENTAS.SemanticModel
