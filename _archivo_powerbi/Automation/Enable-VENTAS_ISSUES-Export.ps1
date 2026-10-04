$ErrorActionPreference = "Stop"
$AutomationRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$MonitorPath = Join-Path $AutomationRoot "Monitor-ProyectoConcurso.ps1"
$BackupPath = Join-Path $AutomationRoot "Monitor-ProyectoConcurso.before-export.ps1"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

if (-not (Test-Path -LiteralPath $MonitorPath)) { throw "No se encontro $MonitorPath" }
$text = [System.IO.File]::ReadAllText($MonitorPath)
if ($text.Contains('Export-VENTAS_ISSUES.ps1')) {
    Write-Host "El monitor ya contiene la integracion de exportacion."
    exit 0
}
[System.IO.File]::WriteAllText($BackupPath,$text,$Utf8NoBom)

$text = $text.Replace(
    '$FileUpdaterPath = Join-Path $AutomationRoot "Update-DimArchivoLocal.ps1"',
    '$FileUpdaterPath = Join-Path $AutomationRoot "Update-DimArchivoLocal.ps1"' + [Environment]::NewLine + '$ExporterPath = Join-Path $AutomationRoot "Export-VENTAS_ISSUES.ps1"'
)

$anchor = @'
function Get-DirectorySignature {
'@
$exportFunction = @'
function Invoke-Exporter {
    if (-not (Test-Path -LiteralPath $ExporterPath)) { return }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ExporterPath -Silent
    if ($LASTEXITCODE -ne 0) {
        Write-MonitorLog "Exportador VENTAS_ISSUES devolvio codigo $LASTEXITCODE."
    }
}

function Get-DirectorySignature {
'@
if (-not $text.Contains($anchor.TrimStart("`r","`n"))) { throw "No se encontro el ancla Get-DirectorySignature." }
$text = $text.Replace($anchor.TrimStart("`r","`n"),$exportFunction.TrimStart("`r","`n"))

$scanAnchor = '$nextDirectoryScan = (Get-Date).AddSeconds(10)'
if (-not $text.Contains($scanAnchor)) { throw "No se encontro nextDirectoryScan." }
$text = $text.Replace($scanAnchor,$scanAnchor + [Environment]::NewLine + '    $nextExportCheck = (Get-Date).AddSeconds(20)')

$loopAnchor = '        $wasOpen = $isOpen'
$loopBlock = @'
        $wasOpen = $isOpen

        # El exportador solo puede consultar VENTAS_ISSUES mientras Power BI Desktop esta abierto.
        # No ejecuta Refresh; exporta el estado actualmente cargado en el modelo.
        if ($isOpen -and (Get-Date) -ge $nextExportCheck) {
            Invoke-Exporter
            $nextExportCheck = (Get-Date).AddMinutes(1)
        }
'@
if (-not $text.Contains($loopAnchor)) { throw "No se encontro el ancla wasOpen." }
$text = $text.Replace($loopAnchor,$loopBlock.TrimEnd("`r","`n"))

[System.IO.File]::WriteAllText($MonitorPath,$text,$Utf8NoBom)
Write-Host "Monitor actualizado. Respaldo: $BackupPath"
