@echo off
REM Genera Data\VENTAS_ISSUES.json y Dashboard\Issues-Ventas-Report.html desde ACC. No necesita Power BI.
cd /d "%~dp0"
python -m issues_sync run
if errorlevel 1 pause
