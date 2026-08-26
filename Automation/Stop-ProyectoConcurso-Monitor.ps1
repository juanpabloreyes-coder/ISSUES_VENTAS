$pidPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "monitor.pid"
if (Test-Path -LiteralPath $pidPath) {
    $monitorPid = [int]([System.IO.File]::ReadAllText($pidPath).Trim())
    Stop-Process -Id $monitorPid -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
}
