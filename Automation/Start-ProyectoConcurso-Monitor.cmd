@echo off
start "ProyectoConcurso Monitor" /min powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Monitor-ProyectoConcurso.ps1"
