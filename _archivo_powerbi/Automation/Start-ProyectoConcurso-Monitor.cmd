@echo off
start "ProyectoConcurso Monitor" /min powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Monitor-ProyectoConcurso.ps1"

start "VENTAS Issues Export Monitor" /min powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Monitor-VENTAS_ISSUES-Export.ps1" -IntervalSeconds 60
