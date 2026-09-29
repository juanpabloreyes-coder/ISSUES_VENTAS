@echo off
title Activando notificaciones de ProyectoConcurso
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Stop-ProyectoConcurso-Monitor.ps1"
timeout /t 2 /nobreak >nul
start "ProyectoConcurso Monitor" /min powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Monitor-ProyectoConcurso.ps1"
timeout /t 3 /nobreak >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-ProyectoConcurso-Notification.ps1"
exit
