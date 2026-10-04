param(
    [int]$IntervalSeconds = 60
)

$ErrorActionPreference = "Continue"

$AutomationRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = Split-Path -Parent $AutomationRoot
$PbipPath = Join-Path $RepositoryRoot "ISSUES_VENTAS.pbip"
$PbipName = [System.IO.Path]::GetFileName($PbipPath)
$ExportPath = Join-Path $AutomationRoot "Export-VENTAS_ISSUES.ps1"
$JsonPath = Join-Path $RepositoryRoot "Data\VENTAS_ISSUES.json"
$HtmlPath = Join-Path $RepositoryRoot "Dashboard\Issues-Ventas-Report.html"
$PidPath = Join-Path $AutomationRoot "export-monitor.pid"
$LogPath = Join-Path $AutomationRoot "export-monitor.log"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-ExportMonitorLog {
    param([string]$Message)
    $line = "{0}  EXPORT_MONITOR  {1}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $Message
    try {
        [System.IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine, $Utf8NoBom)
    } catch {}
}

function Test-TargetOpen {
    try {
        foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='PBIDesktop.exe'" -ErrorAction Stop)) {
            $cmd = [string]$process.CommandLine
            if (-not [string]::IsNullOrWhiteSpace($cmd)) {
                if ($cmd.IndexOf($PbipName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    return $true
                }
            }
        }
    } catch {}

    try {
        foreach ($window in @(Get-Process PBIDesktop -ErrorAction SilentlyContinue)) {
            $title = [string]$window.MainWindowTitle
            if (-not [string]::IsNullOrWhiteSpace($title) -and
                $title.IndexOf("ISSUES_VENTAS", [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return $true
            }
        }
    } catch {}

    try {
        $pbi = @(Get-Process PBIDesktop -ErrorAction SilentlyContinue)
        $as = @(Get-Process msmdsrv -ErrorAction SilentlyContinue)
        if ($pbi.Count -eq 1 -and $as.Count -eq 1) {
            return $true
        }
    } catch {}

    return $false
}

function Get-RowsFingerprint {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    try {
        $json = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
        $rows = @($json.rows)

        $canonicalRows = foreach ($row in $rows) {
            $props = @(
                "ID",
                "Title",
                "Status",
                "Category",
                "Type",
                "Description",
                "Assigned to",
                "Created by",
                "Created on",
                "Due date",
                "Updated on",
                "Closed by",
                "Closed at",
                "Disciplina",
                "Proyecto",
                "Equipo",
                "ProyectoConcurso"
            )

            $parts = foreach ($p in $props) {
                $value = $row.PSObject.Properties[$p].Value
                if ($null -eq $value) { $value = "" }
                "$p=$([string]$value)"
            }

            $parts -join "|"
        }

        $canonical = ($canonicalRows | Sort-Object) -join "`n"
        $bytes = $Utf8NoBom.GetBytes($canonical)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
        } finally {
            $sha.Dispose()
        }
    } catch {
        return $null
    }
}

function Restore-IfNoDataChange {
    param(
        [string]$JsonBackup,
        [string]$HtmlBackup
    )

    if ($JsonBackup -and (Test-Path -LiteralPath $JsonBackup)) {
        Copy-Item -LiteralPath $JsonBackup -Destination $JsonPath -Force
    }

    if ($HtmlBackup -and (Test-Path -LiteralPath $HtmlBackup)) {
        Copy-Item -LiteralPath $HtmlBackup -Destination $HtmlPath -Force
    }
}

$createdNew = $false
$mutex = [System.Threading.Mutex]::new(
    $true,
    "Local\VENTAS_ISSUES_Dashboard_Export_Monitor",
    [ref]$createdNew
)

if (-not $createdNew) { exit 0 }

try {
    [System.IO.File]::WriteAllText($PidPath, [string]$PID, $Utf8NoBom)

    if ($IntervalSeconds -lt 30) { $IntervalSeconds = 30 }

    Write-ExportMonitorLog "Monitor iniciado. Intervalo: $IntervalSeconds segundos."

    $lastOpen = $false
    $lastFailure = $null

    while ($true) {
        $isOpen = Test-TargetOpen

        if ($isOpen) {
            if (-not $lastOpen) {
                Write-ExportMonitorLog "ISSUES_VENTAS.pbip detectado abierto."
            }

            if (-not (Test-Path -LiteralPath $ExportPath)) {
                if ($lastFailure -ne "NO_EXPORTER") {
                    Write-ExportMonitorLog "No se encontro Export-VENTAS_ISSUES.ps1."
                    $lastFailure = "NO_EXPORTER"
                }
            } else {
                $beforeFingerprint = Get-RowsFingerprint -Path $JsonPath

                $jsonBackup = $null
                $htmlBackup = $null

                try {
                    if (Test-Path -LiteralPath $JsonPath) {
                        $jsonBackup = Join-Path $env:TEMP ("VENTAS_ISSUES_before_" + [guid]::NewGuid().ToString("N") + ".json")
                        Copy-Item -LiteralPath $JsonPath -Destination $jsonBackup -Force
                    }
                    if (Test-Path -LiteralPath $HtmlPath) {
                        $htmlBackup = Join-Path $env:TEMP ("Issues-Ventas-Report_before_" + [guid]::NewGuid().ToString("N") + ".html")
                        Copy-Item -LiteralPath $HtmlPath -Destination $htmlBackup -Force
                    }

                    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ExportPath *> $null
                    $exitCode = $LASTEXITCODE
                } catch {
                    $exitCode = 99
                }

                if ($exitCode -eq 0) {
                    $afterFingerprint = Get-RowsFingerprint -Path $JsonPath

                    if ($beforeFingerprint -and $afterFingerprint -and $beforeFingerprint -eq $afterFingerprint) {
                        Restore-IfNoDataChange -JsonBackup $jsonBackup -HtmlBackup $htmlBackup
                        Write-ExportMonitorLog "Exportacion correcta. Sin cambios reales en los Issues."
                    } elseif (-not $beforeFingerprint -and $afterFingerprint) {
                        Write-ExportMonitorLog "Snapshot inicial generado."
                    } else {
                        Write-ExportMonitorLog "Cambios reales detectados. JSON y dashboard regenerados."
                    }

                    if ($lastFailure) {
                        Write-ExportMonitorLog "Exportador recuperado correctamente."
                    }
                    $lastFailure = $null
                } else {
                    $failure = "EXIT_$exitCode"
                    if ($failure -ne $lastFailure) {
                        Write-ExportMonitorLog "Exportador devolvio codigo $exitCode. Se reintentara automaticamente."
                        $lastFailure = $failure
                    }
                }

                foreach ($tmp in @($jsonBackup, $htmlBackup)) {
                    if ($tmp -and (Test-Path -LiteralPath $tmp)) {
                        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        } elseif ($lastOpen) {
            Write-ExportMonitorLog "ISSUES_VENTAS.pbip cerrado. Exportacion en pausa."
        }

        $lastOpen = $isOpen
        Start-Sleep -Seconds $IntervalSeconds
    }
} catch {
    Write-ExportMonitorLog "Monitor detenido por error: $($_.Exception.Message)"
} finally {
    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
    if ($mutex) {
        try { $mutex.ReleaseMutex() } catch {}
        $mutex.Dispose()
    }
}
