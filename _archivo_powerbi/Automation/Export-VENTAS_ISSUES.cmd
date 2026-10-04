@echo off
setlocal
cd /d "%~dp0"
echo ==============================================
echo   EXPORTADOR VENTAS_ISSUES - Power BI Desktop
echo ==============================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Export-VENTAS_ISSUES.ps1" -Diagnostic
set CODE=%ERRORLEVEL%
echo.
if not "%CODE%"=="0" (
  echo La exportacion termino con error %CODE%.
  echo Copia el texto mostrado arriba y envialo para diagnostico.
) else (
  echo Exportacion finalizada correctamente.
)
echo.
pause
exit /b %CODE%
