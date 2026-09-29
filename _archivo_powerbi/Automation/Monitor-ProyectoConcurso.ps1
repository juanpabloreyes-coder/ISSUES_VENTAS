$ErrorActionPreference = "Continue"

$AutomationRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = Split-Path -Parent $AutomationRoot
$UpdaterPath = Join-Path $AutomationRoot "Update-ProyectoConcurso.ps1"
$FileUpdaterPath = Join-Path $AutomationRoot "Update-DimArchivoLocal.ps1"
$FileStatePath = Join-Path $AutomationRoot "filemap-state.json"
$StatePath = Join-Path $AutomationRoot "state.json"
$SignalPath = Join-Path $AutomationRoot "folder-change.signal"
$PidPath = Join-Path $AutomationRoot "monitor.pid"
$LogPath = Join-Path $AutomationRoot "automation.log"
$ProjectFilesRoot = "C:\Users\Usuario\DC\ACCDocs\GCPEASA\VENTAS GCP\Project Files"
$PbipPath = Join-Path $RepositoryRoot "ISSUES_VENTAS.pbip"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-MonitorLog {
    param([string]$Message)
    $line = "{0}  MONITOR  {1}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $Message
    [System.IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine, $Utf8NoBom)
}

function Show-MonitorNotification {
    param([string]$Title, [string]$Message, [string]$Level = "Info")
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $icon = [System.Windows.Forms.NotifyIcon]::new()
        $icon.Icon = if ($Level -eq "Warning") { [System.Drawing.SystemIcons]::Warning } else { [System.Drawing.SystemIcons]::Information }
        $icon.Visible = $true
        $icon.BalloonTipTitle = $Title
        $icon.BalloonTipText = $Message
        $icon.BalloonTipIcon = if ($Level -eq "Warning") { [System.Windows.Forms.ToolTipIcon]::Warning } else { [System.Windows.Forms.ToolTipIcon]::Info }
        $icon.ShowBalloonTip(8000)
        Start-Sleep -Milliseconds 1200
        $icon.Dispose()
    } catch {
        Write-MonitorLog "No se pudo mostrar notificación: $($_.Exception.Message)"
    }
}

function Read-State {
    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    try { return [System.IO.File]::ReadAllText($StatePath) | ConvertFrom-Json } catch { return $null }
}

function Test-TargetOpen {
    $escapedPbip = [regex]::Escape($PbipPath)
    try {
        foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='PBIDesktop.exe'" -ErrorAction Stop)) {
            if ($process.CommandLine -and $process.CommandLine -match $escapedPbip) { return $true }
        }
    } catch { }
    foreach ($window in @(Get-Process PBIDesktop -ErrorAction SilentlyContinue)) {
        if ($window.MainWindowTitle -match "(^|\s)ISSUES_VENTAS(\s|-|$)") { return $true }
    }
    return $false
}

function Invoke-Updater {
    param([string]$Reason)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $UpdaterPath -Reason $Reason
    $folderExit = $LASTEXITCODE
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FileUpdaterPath -Reason $Reason
    $fileExit = $LASTEXITCODE
    if ($folderExit -eq 10 -or $fileExit -eq 10) { return 10 }
    if ($folderExit -ne 0 -or $fileExit -ne 0) { return 1 }
    return 0
}

function Get-DirectorySignature {
    if (-not (Test-Path -LiteralPath $ProjectFilesRoot)) { return $null }
    try {
        $relativePaths = @(Get-ChildItem -LiteralPath $ProjectFilesRoot -Recurse -ErrorAction Stop |
            ForEach-Object { $_.FullName.Substring($ProjectFilesRoot.Length).TrimStart('\') } |
            Sort-Object)
        $canonical = $relativePaths -join "`n"
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = $Utf8NoBom.GetBytes($canonical)
            return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
        } finally {
            $sha.Dispose()
        }
    } catch {
        Write-MonitorLog "No se pudo calcular la firma de carpetas: $($_.Exception.Message)"
        return $null
    }
}

$createdNew = $false
$mutex = [System.Threading.Mutex]::new($true, "Local\ProyectoConcurso_VENTAS_GCP_Monitor", [ref]$createdNew)
if (-not $createdNew) { exit 0 }
[System.IO.File]::WriteAllText($PidPath, [string]$PID, $Utf8NoBom)

$watcher = $null
try {
    Write-MonitorLog "Monitor iniciado."
    Invoke-Updater -Reason "Inicio del monitor" | Out-Null

    if (Test-Path -LiteralPath $ProjectFilesRoot) {
        $watcher = [System.IO.FileSystemWatcher]::new($ProjectFilesRoot)
        $watcher.IncludeSubdirectories = $true
        $watcher.NotifyFilter = [System.IO.NotifyFilters]::DirectoryName -bor [System.IO.NotifyFilters]::FileName -bor [System.IO.NotifyFilters]::LastWrite
        $watcher.EnableRaisingEvents = $true
        $action = {
            try {
                [System.IO.File]::WriteAllText(
                    $using:SignalPath,
                    (Get-Date).ToString("o"),
                    [System.Text.UTF8Encoding]::new($false)
                )
            } catch { }
        }
        Register-ObjectEvent -InputObject $watcher -EventName Created -Action $action | Out-Null
        Register-ObjectEvent -InputObject $watcher -EventName Deleted -Action $action | Out-Null
        Register-ObjectEvent -InputObject $watcher -EventName Renamed -Action $action | Out-Null
    } else {
        Write-MonitorLog "Desktop Connector todavía no está disponible; se reintentará."
    }

    $wasOpen = $false
    $queued = $false
    $queueReason = ""
    $nextHourlyCheck = (Get-Date).AddHours(1)
    $directorySignature = Get-DirectorySignature
    $nextDirectoryScan = (Get-Date).AddSeconds(10)

    while ($true) {
        $isOpen = Test-TargetOpen
        if ($isOpen -and -not $wasOpen) {
            $state = Read-State
            if ($state -and $state.LastUpdated) {
                $when = ([datetime]$state.LastUpdated).ToLocalTime().ToString("dd/MM/yyyy HH:mm:ss")
                $status = if ($state.Pending) { " Hay una actualización pendiente." } else { "" }
                Show-MonitorNotification -Title "ProyectoConcurso" -Message "Última actualización: $when.$status"
            } else {
                Show-MonitorNotification -Title "ProyectoConcurso" -Message "Aún no existe una actualización registrada." -Level Warning
            }
        }

        if (-not $isOpen -and $wasOpen) {
            $state = Read-State
            if ($state -and $state.Pending) {
                $queued = $true
                $queueReason = "Power BI liberó el archivo"
            }
        }
        $wasOpen = $isOpen

        if (Test-Path -LiteralPath $SignalPath) {
            $signalAge = (Get-Date) - (Get-Item -LiteralPath $SignalPath).LastWriteTime
            if ($signalAge.TotalSeconds -ge 5) {
                $queued = $true
                $queueReason = "Cambio detectado por Desktop Connector"
                Remove-Item -LiteralPath $SignalPath -Force -ErrorAction SilentlyContinue
            }
        }

        if ((Get-Date) -ge $nextHourlyCheck) {
            $queued = $true
            $queueReason = "Revisión horaria"
            $nextHourlyCheck = (Get-Date).AddHours(1)
        }

        if ((Get-Date) -ge $nextDirectoryScan) {
            $currentDirectorySignature = Get-DirectorySignature
            if ($currentDirectorySignature -and $directorySignature -and $currentDirectorySignature -ne $directorySignature) {
                $queued = $true
                $queueReason = "Cambio detectado en la estructura de Desktop Connector"
            }
            if ($currentDirectorySignature) { $directorySignature = $currentDirectorySignature }
            $nextDirectoryScan = (Get-Date).AddSeconds(10)
        }

        $state = Read-State
        $fileState = if (Test-Path -LiteralPath $FileStatePath) { try { Get-Content -Raw $FileStatePath | ConvertFrom-Json } catch { $null } } else { $null }
        if ((($state -and $state.Pending) -or ($fileState -and $fileState.Pending)) -and -not $isOpen) {
            $queued = $true
            if (-not $queueReason) { $queueReason = "Reintento pendiente" }
        }

        if ($queued) {
            $exitCode = Invoke-Updater -Reason $queueReason
            if ($exitCode -eq 0) {
                $queued = $false
                $queueReason = ""
            } elseif ($exitCode -eq 10) {
                $queued = $true
            } else {
                $queued = $false
                $queueReason = ""
            }
        }

        Start-Sleep -Seconds 5
    }
} catch {
    Write-MonitorLog "Monitor detenido por error: $($_.Exception.Message)"
    Show-MonitorNotification -Title "Monitor ProyectoConcurso" -Message "El monitor se detuvo: $($_.Exception.Message)" -Level Warning
} finally {
    Get-EventSubscriber | Where-Object { $_.SourceObject -eq $watcher } | Unregister-Event -Force -ErrorAction SilentlyContinue
    if ($watcher) { $watcher.Dispose() }
    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
    if ($mutex) { $mutex.ReleaseMutex(); $mutex.Dispose() }
}
