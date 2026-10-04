$pidPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "monitor.pid"
if (Test-Path -LiteralPath $pidPath) {
    $monitorPid = [int]([System.IO.File]::ReadAllText($pidPath).Trim())
    Stop-Process -Id $monitorPid -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
}


# BEGIN VENTAS_ISSUES_EXPORT_MONITOR
$exportPidPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "export-monitor.pid"
if (Test-Path -LiteralPath $exportPidPath) {
    try {
        $exportMonitorPid = [int](([System.IO.File]::ReadAllText($exportPidPath) -replace '[^0-9]', ''))
        if ($exportMonitorPid -gt 0) {
            Stop-Process -Id $exportMonitorPid -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    Remove-Item -LiteralPath $exportPidPath -Force -ErrorAction SilentlyContinue
}
# END VENTAS_ISSUES_EXPORT_MONITOR