param(
    [string]$Reason = "Revisión programada",
    [switch]$Force,
    [switch]$Silent
)

$ErrorActionPreference = "Stop"

$ProjectFilesRoot = "C:\Users\Usuario\DC\ACCDocs\GCPEASA\VENTAS GCP\Project Files"
$AutomationRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = Split-Path -Parent $AutomationRoot
$PbipPath = Join-Path $RepositoryRoot "ISSUES_VENTAS.pbip"
$DefinitionPath = Join-Path $RepositoryRoot "ISSUES_VENTAS.SemanticModel\definition"
$TmdlPath = Join-Path $DefinitionPath "tables\DimProyectoConcurso.tmdl"
$StatePath = Join-Path $AutomationRoot "state.json"
$BackupPath = Join-Path $AutomationRoot "DimProyectoConcurso.last-good.tmdl"
$LogPath = Join-Path $AutomationRoot "automation.log"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-Log {
    param([string]$Message)
    $line = "{0}  {1}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $Message
    [System.IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine, $Utf8NoBom)
}

function Show-Notification {
    param(
        [string]$Title,
        [string]$Message,
        [ValidateSet("Info", "Warning", "Error")]
        [string]$Level = "Info"
    )
    if ($Silent) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $icon = [System.Windows.Forms.NotifyIcon]::new()
        $icon.Icon = switch ($Level) {
            "Warning" { [System.Drawing.SystemIcons]::Warning }
            "Error" { [System.Drawing.SystemIcons]::Error }
            default { [System.Drawing.SystemIcons]::Information }
        }
        $icon.Visible = $true
        $icon.BalloonTipTitle = $Title
        $icon.BalloonTipText = $Message
        $icon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::$Level
        $icon.ShowBalloonTip(8000)
        Start-Sleep -Milliseconds 1200
        $icon.Dispose()
    } catch {
        Write-Log "No se pudo mostrar la notificación: $($_.Exception.Message)"
    }
}

function Read-State {
    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    try {
        return [System.IO.File]::ReadAllText($StatePath) | ConvertFrom-Json
    } catch {
        Write-Log "No se pudo leer state.json: $($_.Exception.Message)"
        return $null
    }
}

function Save-State {
    param([hashtable]$State)
    $json = $State | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($StatePath, $json, $Utf8NoBom)
}

function Test-TargetPowerBiOpen {
    $escapedPbip = [regex]::Escape($PbipPath)
    try {
        $processes = @(Get-CimInstance Win32_Process -Filter "Name='PBIDesktop.exe'" -ErrorAction Stop)
        foreach ($process in $processes) {
            if ($process.CommandLine -and $process.CommandLine -match $escapedPbip) { return $true }
        }
    } catch {
        Write-Log "No se pudo consultar la línea de comandos de Power BI: $($_.Exception.Message)"
    }

    $windows = @(Get-Process PBIDesktop -ErrorAction SilentlyContinue)
    foreach ($window in $windows) {
        if ($window.MainWindowTitle -match "(^|\s)ISSUES_VENTAS(\s|-|$)") { return $true }
    }
    return $false
}

function Test-TmdlWritable {
    try {
        $stream = [System.IO.File]::Open(
            $TmdlPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        $stream.Dispose()
        return $true
    } catch {
        return $false
    }
}

if (-not ("ProyectoConcursoReparseReader" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using System.Text;
using System.Text.RegularExpressions;

public static class ProyectoConcursoReparseReader
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(
        string name, uint access, uint share, IntPtr security,
        uint creation, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(
        SafeFileHandle handle, uint code, IntPtr input, int inputSize,
        byte[] output, int outputSize, out int returned, IntPtr overlapped);

    public static string FolderUrn(string path)
    {
        using (var handle = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero))
        {
            if (handle.IsInvalid) return null;
            var buffer = new byte[16384];
            int returned;
            if (!DeviceIoControl(handle, 0x000900A8, IntPtr.Zero, 0, buffer, buffer.Length, out returned, IntPtr.Zero))
                return null;

            var text = new StringBuilder();
            for (var i = 0; i < returned; i++)
                if (buffer[i] >= 32 && buffer[i] <= 126)
                    text.Append((char)buffer[i]);

            var match = Regex.Match(text.ToString(), @"urn:adsk\.wipprod:fs\.folder:[A-Za-z0-9._-]+");
            return match.Success ? match.Value : null;
        }
    }
}
'@
}

function Get-FolderMap {
    if (-not (Test-Path -LiteralPath $ProjectFilesRoot)) {
        throw "Desktop Connector no tiene disponible: $ProjectFilesRoot"
    }

    $map = @{}
    $folders = @(Get-ChildItem -LiteralPath $ProjectFilesRoot -Directory -Recurse -ErrorAction Stop)
    foreach ($folder in $folders) {
        $urn = [ProyectoConcursoReparseReader]::FolderUrn($folder.FullName)
        if (-not $urn) { continue }
        $relative = $folder.FullName.Substring($ProjectFilesRoot.Length).TrimStart('\')
        $projectName = ($relative -split '\\')[0]
        if ([string]::IsNullOrWhiteSpace($projectName)) { continue }
        $map[$urn] = $projectName
    }
    if ($map.Count -eq 0) {
        throw "No se encontraron identificadores de carpetas en Desktop Connector."
    }
    return $map
}

function Get-Fingerprint {
    param([hashtable]$Map)
    $canonical = ($Map.Keys | Sort-Object | ForEach-Object { "$_|$($Map[$_])" }) -join "`n"
    $bytes = $Utf8NoBom.GetBytes($canonical)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-EmbeddedMap {
    param([string]$Text)
    $map = @{}
    $pattern = '\{"(?<urn>urn:adsk\.wipprod:fs\.folder:[^"]+)",\s*"(?<project>[^"]+)"\}'
    foreach ($match in [regex]::Matches($Text, $pattern)) {
        $map[$match.Groups["urn"].Value] = $match.Groups["project"].Value.Replace('""', '"')
    }
    return $map
}

function New-LocalMapBlock {
    param([hashtable]$Map)
    $rows = @($Map.Keys | Sort-Object | ForEach-Object {
        $urn = $_.Replace('"', '""')
        $project = $Map[$_].Replace('"', '""')
        "                                {`"$urn`", `"$project`"}"
    })

    $rowText = for ($index = 0; $index -lt $rows.Count; $index++) {
        if ($index -lt ($rows.Count - 1)) { $rows[$index] + "," } else { $rows[$index] }
    }

    return @"
				    LocalFolderMap = Table.Buffer(
				        #table(
				            type table [FolderKey = nullable text, ProyectoConcursoLocal = nullable text],
				            {
$($rowText -join [Environment]::NewLine)
				            }
				        )
				    ),
"@
}

function Validate-Tmdl {
    $assemblyPath = "C:\Program Files\Microsoft Power BI Desktop\bin\Microsoft.PowerBI.Amo.dll"
    if (-not (Test-Path -LiteralPath $assemblyPath)) {
        throw "No se encontró Microsoft.PowerBI.Amo.dll para validar el modelo."
    }
    [void][System.Reflection.Assembly]::LoadFrom($assemblyPath)
    $database = [Microsoft.AnalysisServices.TmdlSerializer]::DeserializeDatabaseFromFolder($DefinitionPath)
    $validation = $database.Model.Validate()
    if ($validation.ContainsErrors -or @($validation.Errors).Count -gt 0) {
        throw "La validación del modelo devolvió errores."
    }
}

try {
    Write-Log "Inicio: $Reason"
    $map = Get-FolderMap
    $fingerprint = Get-Fingerprint -Map $map
    $state = Read-State
    $tmdlText = [System.IO.File]::ReadAllText($TmdlPath)
    $embeddedMap = Get-EmbeddedMap -Text $tmdlText
    $embeddedFingerprint = Get-Fingerprint -Map $embeddedMap
    $now = (Get-Date).ToString("o")

    if (-not $Force -and $fingerprint -eq $embeddedFingerprint) {
        $lastUpdated = if ($state -and $state.LastUpdated) {
            [string]$state.LastUpdated
        } else {
            (Get-Item -LiteralPath $TmdlPath).LastWriteTime.ToString("o")
        }
        Save-State @{
            Fingerprint = $fingerprint
            FolderCount = $map.Count
            LastChecked = $now
            LastUpdated = $lastUpdated
            LastReason = if ($state) { [string]$state.LastReason } else { "Mapa inicial verificado" }
            Status = "Actualizado"
            Pending = $false
            LastError = $null
        }
        Write-Log "Sin cambios: $($map.Count) carpetas."
        exit 0
    }

    if ((Test-TargetPowerBiOpen) -or -not (Test-TmdlWritable)) {
        $alreadyPending = $state -and $state.Pending
        Save-State @{
            Fingerprint = if ($state) { [string]$state.Fingerprint } else { $embeddedFingerprint }
            PendingFingerprint = $fingerprint
            FolderCount = $map.Count
            LastChecked = $now
            LastUpdated = if ($state) { [string]$state.LastUpdated } else { $null }
            LastReason = $Reason
            Status = "Esperando a que Power BI cierre el archivo"
            Pending = $true
            LastError = $null
        }
        if (-not $alreadyPending) {
            Show-Notification -Title "ProyectoConcurso pendiente" -Message "Se detectó un cambio. El mapa se actualizará al cerrar Power BI." -Level Warning
        }
        Write-Log "Cambio pendiente: Power BI está usando el archivo."
        exit 10
    }

    Show-Notification -Title "ProyectoConcurso" -Message "Actualizando el mapa de carpetas de VENTAS GCP..."
    Save-State @{
        Fingerprint = if ($state) { [string]$state.Fingerprint } else { $embeddedFingerprint }
        PendingFingerprint = $fingerprint
        FolderCount = $map.Count
        LastChecked = $now
        LastUpdated = if ($state) { [string]$state.LastUpdated } else { $null }
        LastReason = $Reason
        Status = "Actualizando"
        Pending = $true
        LastError = $null
    }

    [System.IO.File]::WriteAllText($BackupPath, $tmdlText, $Utf8NoBom)
    $pattern = '(?ms)^[ \t]*LocalFolderMap = Table\.Buffer\(.*?^(?<system>[ \t]*SystemRoots\s*=)'
    $match = [regex]::Match($tmdlText, $pattern)
    if (-not $match.Success) {
        throw "No se encontró el bloque LocalFolderMap dentro de DimProyectoConcurso.tmdl."
    }
    $replacement = (New-LocalMapBlock -Map $map).TrimEnd("`r", "`n") + [Environment]::NewLine + $match.Groups["system"].Value
    $newText = $tmdlText.Substring(0, $match.Index) + $replacement + $tmdlText.Substring($match.Index + $match.Length)
    [System.IO.File]::WriteAllText($TmdlPath, $newText, $Utf8NoBom)

    try {
        Validate-Tmdl
        $writtenText = [System.IO.File]::ReadAllText($TmdlPath)
        $writtenMap = Get-EmbeddedMap -Text $writtenText
        if ($writtenMap.Count -ne $map.Count -or (Get-Fingerprint -Map $writtenMap) -ne $fingerprint) {
            throw "El mapa escrito no coincide con Desktop Connector."
        }
    } catch {
        [System.IO.File]::WriteAllText($TmdlPath, [System.IO.File]::ReadAllText($BackupPath), $Utf8NoBom)
        throw
    }

    $finished = (Get-Date).ToString("o")
    Save-State @{
        Fingerprint = $fingerprint
        FolderCount = $map.Count
        LastChecked = $finished
        LastUpdated = $finished
        LastReason = $Reason
        Status = "Actualizado"
        Pending = $false
        LastError = $null
    }
    Write-Log "Actualización completada: $($map.Count) carpetas."
    Show-Notification -Title "ProyectoConcurso actualizado" -Message "Mapa actualizado correctamente: $($map.Count) carpetas."
    exit 0
} catch {
    $message = $_.Exception.Message
    $previous = Read-State
    Save-State @{
        Fingerprint = if ($previous) { [string]$previous.Fingerprint } else { $null }
        FolderCount = if ($previous) { $previous.FolderCount } else { 0 }
        LastChecked = (Get-Date).ToString("o")
        LastUpdated = if ($previous) { [string]$previous.LastUpdated } else { $null }
        LastReason = $Reason
        Status = "Error"
        Pending = $true
        LastError = $message
    }
    Write-Log "ERROR: $message"
    Show-Notification -Title "Error en ProyectoConcurso" -Message $message -Level Error
    exit 1
}
