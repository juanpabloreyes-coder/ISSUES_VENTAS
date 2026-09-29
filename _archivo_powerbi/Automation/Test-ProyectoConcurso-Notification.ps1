$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$icon = [System.Windows.Forms.NotifyIcon]::new()
try {
    $icon.Icon = [System.Drawing.SystemIcons]::Information
    $icon.Visible = $true
    $icon.BalloonTipTitle = "ProyectoConcurso - prueba"
    $icon.BalloonTipText = "El monitor ya puede mostrar notificaciones en Windows."
    $icon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $icon.ShowBalloonTip(10000)
    Start-Sleep -Seconds 4
} finally {
    $icon.Dispose()
}
