param(
    [int]$Port = 0,
    [switch]$Diagnostic
)

$ErrorActionPreference = "Stop"

$AutomationRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = Split-Path -Parent $AutomationRoot
$LogPath = Join-Path $AutomationRoot "automation.log"

$DataDir = Join-Path $RepositoryRoot "Data"
$DashboardDir = Join-Path $RepositoryRoot "Dashboard"

$TemplatePath = Join-Path $DashboardDir "Issues-Ventas-Report.template.html"
$JsonPath = Join-Path $DataDir "VENTAS_ISSUES.json"
$HtmlPath = Join-Path $DashboardDir "Issues-Ventas-Report.html"

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$DepsRoot = Join-Path $env:LOCALAPPDATA "ISSUES_VENTAS\deps"
$PackageVersion = "19.114.12"
$PackageName = "Microsoft.AnalysisServices.AdomdClient"


# ============================================================
# LOG
# ============================================================

function Write-Log {
    param(
        [string]$Message
    )

    $line = "{0}  EXPORT  {1}" -f `
        (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"),
        $Message

    try {
        [System.IO.File]::AppendAllText(
            $LogPath,
            $line + [Environment]::NewLine,
            $Utf8NoBom
        )
    }
    catch {
    }

    if ($Diagnostic) {
        Write-Host $Message
    }
}


# ============================================================
# ERROR
# ============================================================

function Fail {
    param(
        [string]$Message,
        [int]$Code = 2
    )

    Write-Host ""
    Write-Host "ERROR: $Message" -ForegroundColor Red
    Write-Host ""
    Write-Host "EXPORTACION FALLIDA" -ForegroundColor Red
    Write-Host $Message
    Write-Host "Log: $LogPath"

    exit $Code
}


# ============================================================
# DIRECTORIOS
# ============================================================

function Ensure-Directory {
    param(
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        [void][System.IO.Directory]::CreateDirectory($Path)
    }
}


# ============================================================
# ADOMD
# ============================================================

function Load-Adomd {

    $dll = Get-ChildItem `
        -LiteralPath $DepsRoot `
        -Recurse `
        -Filter "Microsoft.AnalysisServices.AdomdClient.dll" `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -match '\\net472\\'
        } |
        Select-Object -First 1

    if (-not $dll) {
        throw "ADOMD no esta disponible en $DepsRoot. Ejecuta primero el fix v5/v6 o vuelve a descargar dependencias."
    }

    $dir = Split-Path -Parent $dll.FullName

    Get-ChildItem `
        -LiteralPath $dir `
        -Filter "*.dll" `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -ne "Microsoft.AnalysisServices.AdomdClient.dll"
        } |
        ForEach-Object {
            try {
                [void][System.Reflection.Assembly]::LoadFrom($_.FullName)
            }
            catch {
            }
        }

    [void][System.Reflection.Assembly]::LoadFrom($dll.FullName)

    Write-Host "ADOMD cargado: $($dll.FullName)"
}


# ============================================================
# DETECTAR PUERTOS DE POWER BI
# ============================================================

function Get-PowerBiPorts {
    param(
        [int]$ManualPort
    )

    if ($ManualPort -gt 0) {
        Write-Host "Puerto indicado manualmente: $ManualPort"
        return @($ManualPort)
    }

    $workspaceRoot = Join-Path `
        $env:LOCALAPPDATA `
        "Microsoft\Power BI Desktop\AnalysisServicesWorkspaces"

    if ($Diagnostic) {
        Write-Host "Workspace root: $workspaceRoot"
    }

    $ports = @()

    if (Test-Path -LiteralPath $workspaceRoot) {

        $files = @(
            Get-ChildItem `
                -LiteralPath $workspaceRoot `
                -Recurse `
                -Filter "msmdsrv.port.txt" `
                -ErrorAction SilentlyContinue
        )

        if ($Diagnostic) {
            Write-Host "Port files encontrados: $($files.Count)"
        }

        foreach ($f in $files) {

            try {

                $raw = [System.IO.File]::ReadAllText($f.FullName)
                $clean = $raw -replace '[^0-9]', ''

                if ($clean) {

                    $p = [int]$clean

                    if (($p -gt 0) -and ($ports -notcontains $p)) {

                        $ports += $p

                        if ($Diagnostic) {
                            Write-Host "  $($f.FullName) -> $p"
                        }
                    }
                }
            }
            catch {

                if ($Diagnostic) {
                    Write-Host "  No se pudo leer $($f.FullName): $($_.Exception.Message)"
                }
            }
        }
    }

    return @($ports)
}


# ============================================================
# DETECTAR TEXTO MAL CODIFICADO
# ============================================================

function Get-BadEncodingCount {
    param(
        [string]$Text
    )

    if ($null -eq $Text) {
        return 0
    }

    $count = 0

    foreach ($code in @(0x00C3, 0x00C2, 0x00E2, 0x00F0)) {

        $ch = [char]$code

        $count += (
            [regex]::Matches(
                $Text,
                [regex]::Escape([string]$ch)
            )
        ).Count
    }

    return $count
}


# ============================================================
# REPARAR MOJIBAKE
# ============================================================

function Repair-Mojibake {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    $s = [string]$Value

    for ($pass = 0; $pass -lt 2; $pass++) {

        $oldBad = Get-BadEncodingCount $s

        if ($oldBad -eq 0) {
            break
        }

        try {

            $bytes = [System.Text.Encoding]::GetEncoding(1252).GetBytes($s)
            $fixed = [System.Text.Encoding]::UTF8.GetString($bytes)

            $newBad = Get-BadEncodingCount $fixed

            if ($newBad -lt $oldBad) {
                $s = $fixed
            }
            else {
                break
            }
        }
        catch {
            break
        }
    }

    $division = [string][char]0x00F7
    $middot = [string][char]0x00B7

    $s = $s.Replace(
        " $division ",
        " $middot "
    )

    return $s
}


# ============================================================
# FIRMA DE LOS DATOS
#
# Sirve para detectar si VENTAS_ISSUES realmente cambio.
# No utiliza generatedAt, puerto ni catalogo.
# ============================================================

function Get-RowsSignature {
    param(
        [array]$Rows
    )

    $rowsArray = @($Rows)

    if ($rowsArray.Count -eq 0) {
        return ""
    }

    $orderedRows = @(
        $rowsArray |
        Sort-Object `
            @{Expression = { [string]$_.ID }},
            @{Expression = { [string]$_.'Updated on' }},
            @{Expression = { [string]$_.Title }}
    )

    $canonicalJson = $orderedRows |
        ConvertTo-Json -Depth 8 -Compress

    $bytes = [System.Text.Encoding]::UTF8.GetBytes(
        $canonicalJson
    )

    $sha = New-Object System.Security.Cryptography.SHA256Managed

    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }

    return (
        [System.BitConverter]::ToString($hash)
    ).Replace("-", "").ToLowerInvariant()
}


# ============================================================
# CONSULTAR MODELO POWER BI
# ============================================================

function Query-Model {
    param(
        [int]$P
    )

    $cs = `
        "Data Source=localhost:$P;" +
        "Integrated Security=SSPI;" +
        "Persist Security Info=True;" +
        "Impersonation Level=Impersonate"

    $conn = New-Object `
        Microsoft.AnalysisServices.AdomdClient.AdomdConnection($cs)

    try {

        $conn.Open()

        if ($Diagnostic) {
            Write-Host "Conectado a localhost:$P"
        }

        $catalogs = $conn.GetSchemaDataSet(
            "DBSCHEMA_CATALOGS",
            $null
        ).Tables[0]

        foreach ($row in $catalogs.Rows) {

            $catalog = [string]$row["CATALOG_NAME"]

            if ([string]::IsNullOrWhiteSpace($catalog)) {
                continue
            }

            $conn.ChangeDatabase($catalog)

            $cmd = $conn.CreateCommand()

            $cmd.CommandText = @"
EVALUATE
SELECTCOLUMNS(
    'VENTAS_ISSUES',
    "ID", 'VENTAS_ISSUES'[ID],
    "Title", 'VENTAS_ISSUES'[Title],
    "Status", 'VENTAS_ISSUES'[Status],
    "Category", 'VENTAS_ISSUES'[Category],
    "Type", 'VENTAS_ISSUES'[Type],
    "Description", 'VENTAS_ISSUES'[Description],
    "Assigned to", 'VENTAS_ISSUES'[Assigned to],
    "Created by", 'VENTAS_ISSUES'[Created by],
    "Created on", 'VENTAS_ISSUES'[Created on],
    "Due date", 'VENTAS_ISSUES'[Due date],
    "Updated on", 'VENTAS_ISSUES'[Updated on],
    "Closed by", 'VENTAS_ISSUES'[Closed by],
    "Closed at", 'VENTAS_ISSUES'[Closed at],
    "Disciplina", 'VENTAS_ISSUES'[Disciplina],
    "Proyecto", 'VENTAS_ISSUES'[Proyecto],
    "Equipo", 'VENTAS_ISSUES'[Equipo],
    "ProyectoConcurso", 'VENTAS_ISSUES'[ProyectoConcurso]
)
"@

            try {

                $reader = $cmd.ExecuteReader()

                $items = @()
                $fieldCount = $reader.FieldCount

                if ($Diagnostic) {
                    Write-Host "Catalogo '$catalog' expone VENTAS_ISSUES. Columnas devueltas: $fieldCount"
                }

                if (($Diagnostic) -and ($fieldCount -gt 0)) {

                    $header = (
                        ([string]$reader.GetName(0)).Trim()
                    ).TrimStart("[", " ").TrimEnd("]", " ")

                    Write-Host "Primer encabezado normalizado: $header"
                }

                while ($reader.Read()) {

                    $o = [ordered]@{}

                    for ($i = 0; $i -lt $fieldCount; $i++) {

                        $name = (
                            [string]$reader.GetName($i)
                        ).Trim()

                        $name = $name.TrimStart(
                            "[",
                            " "
                        ).TrimEnd(
                            "]",
                            " "
                        )

                        if ($reader.IsDBNull($i)) {

                            $value = $null

                        }
                        else {

                            $value = $reader.GetValue($i)

                            if ($value -is [datetime]) {

                                $value = $value.ToString("o")

                            }
                            elseif ($value -is [System.DBNull]) {

                                $value = $null

                            }
                            elseif ($value -is [string]) {

                                $value = Repair-Mojibake $value

                            }
                            elseif ($value -isnot [ValueType]) {

                                $value = Repair-Mojibake ([string]$value)
                            }
                        }

                        $o[$name] = $value
                    }

                    $items += [pscustomobject]$o
                }

                $reader.Close()

                if ($Diagnostic) {
                    Write-Host "Filas leidas: $($items.Count)"
                }

                return [pscustomobject]@{
                    Port = $P
                    Catalog = $catalog
                    Rows = $items
                }
            }
            catch {

                if ($Diagnostic) {

                    Write-Host "Catalogo '$catalog' fallo al consultar/procesar VENTAS_ISSUES:"
                    Write-Host "  $($_.Exception.GetType().FullName): $($_.Exception.Message)"

                    if ($_.ScriptStackTrace) {
                        Write-Host "  Stack: $($_.ScriptStackTrace)"
                    }
                }
            }
        }

        throw "Ningun catalogo de localhost:$P expuso VENTAS_ISSUES con las columnas requeridas."
    }
    finally {

        try {
            $conn.Close()
        }
        catch {
        }

        try {
            $conn.Dispose()
        }
        catch {
        }
    }
}


# ============================================================
# PROCESO PRINCIPAL
# ============================================================

try {

    Load-Adomd

    Write-Host "Buscando el modelo VENTAS_ISSUES abierto en Power BI Desktop..."

    $ports = @(
        Get-PowerBiPorts -ManualPort $Port
    )

    if ((-not $ports) -or ($ports.Count -eq 0)) {
        throw "No se encontro una instancia local de Analysis Services de Power BI."
    }

    Write-Host "Instancias locales detectadas: $($ports -join ', ')"

    $result = $null
    $errors = @()

    foreach ($p in $ports) {

        try {

            $result = Query-Model -P $p

            if ($result) {
                break
            }
        }
        catch {

            $errors += "Puerto $p -> $($_.Exception.Message)"
        }
    }


    # ========================================================
    # MODELO NO ENCONTRADO
    #
    # No se escribe ningun archivo.
    # JSON y HTML anteriores permanecen intactos.
    # ========================================================

    if (-not $result) {

        throw `
            "Power BI esta abierto, pero no fue posible consultar VENTAS_ISSUES. Detalle: $($errors -join ' | ')"
    }


    $newRows = @(
        $result.Rows
    )

    $newRowCount = $newRows.Count


    # ========================================================
    # PROTECCION 1
    # NUNCA REEMPLAZAR DATOS VALIDOS POR 0 FILAS
    # ========================================================

    if ($newRowCount -eq 0) {

        Write-Host ""
        Write-Host "SIN ACTUALIZACION" -ForegroundColor Yellow
        Write-Host "VENTAS_ISSUES devolvio 0 registros."
        Write-Host "Se conserva intacto el ultimo JSON y HTML validos."

        Write-Log `
            "Exportacion omitida: VENTAS_ISSUES devolvio 0 registros. Se conserva el ultimo JSON y HTML validos."

        exit 0
    }


    # ========================================================
    # LEER SNAPSHOT ANTERIOR
    # ========================================================

    $previousSnapshot = $null
    $previousRows = @()
    $previousRowCount = 0
    $previousSignature = ""

    if (Test-Path -LiteralPath $JsonPath) {

        try {

            $previousJson = [System.IO.File]::ReadAllText(
                $JsonPath
            )

            if (-not [string]::IsNullOrWhiteSpace($previousJson)) {

                $previousSnapshot = $previousJson |
                    ConvertFrom-Json

                $previousRows = @(
                    $previousSnapshot.rows
                )

                $previousRowCount = $previousRows.Count

                if ($previousRowCount -gt 0) {

                    $previousSignature = Get-RowsSignature `
                        -Rows $previousRows
                }
            }
        }
        catch {

            if ($Diagnostic) {
                Write-Host "No se pudo leer/comparar el JSON anterior: $($_.Exception.Message)"
            }
        }
    }


    # ========================================================
    # PROTECCION 2
    # SI LOS DATOS SON IDENTICOS NO REESCRIBIR JSON/HTML
    # ========================================================

    $newSignature = Get-RowsSignature `
        -Rows $newRows

    if (
        ($previousRowCount -gt 0) -and
        (-not [string]::IsNullOrWhiteSpace($previousSignature)) -and
        ($previousSignature -eq $newSignature)
    ) {

        Write-Host ""
        Write-Host "SIN CAMBIOS EN VENTAS_ISSUES" -ForegroundColor Cyan
        Write-Host "Registros actuales: $newRowCount"
        Write-Host "El JSON y el HTML existentes se conservan intactos."

        if (
            ($null -ne $previousSnapshot) -and
            ($null -ne $previousSnapshot.generatedAt)
        ) {

            Write-Host "Ultima exportacion valida: $($previousSnapshot.generatedAt)"
        }

        Write-Log `
            "Sin cambios en VENTAS_ISSUES. Se conservan JSON y HTML existentes. $newRowCount registros."

        exit 0
    }


    # ========================================================
    # HAY DATOS NUEVOS Y VALIDOS
    # ========================================================

    Ensure-Directory $DataDir
    Ensure-Directory $DashboardDir


    $snapshot = [ordered]@{

        generatedAt =
            (Get-Date).ToString("o")

        source =
            "Power BI Desktop / VENTAS_ISSUES"

        port =
            $result.Port

        catalog =
            $result.Catalog

        rowCount =
            $newRowCount

        rows =
            $newRows
    }


    $json = $snapshot |
        ConvertTo-Json -Depth 8


    # ========================================================
    # GENERAR EL HTML EN MEMORIA ANTES DE SOBRESCRIBIR
    # ========================================================

    $html = $null

    if (Test-Path -LiteralPath $TemplatePath) {

        $template = [System.IO.File]::ReadAllText(
            $TemplatePath
        )

        $template = Repair-Mojibake $template

        $template = $template.Replace(
            '__ISSUES_DATA_JSON__',
            ''
        )

        $safeJson = $json.Replace(
            "</script>",
            "<\/script>"
        )

        $marker =
            '<script id="issues-data" type="application/json"></script>'

        if ($template.Contains($marker)) {

            $html = $template.Replace(
                $marker,
                '<script id="issues-data" type="application/json">' +
                $safeJson +
                '</script>'
            )
        }
        else {

            $html = $template.Replace(
                '</body>',
                '<script id="issues-data" type="application/json">' +
                $safeJson +
                '</script></body>'
            )
        }
    }
    else {

        throw "No se encontro la plantilla HTML: $TemplatePath"
    }


    if ([string]::IsNullOrWhiteSpace($html)) {

        throw "No fue posible generar el HTML nuevo. Se conserva la version anterior."
    }


    # ========================================================
    # ESCRIBIR SOLO DESPUES DE TODAS LAS VALIDACIONES
    # ========================================================

    [System.IO.File]::WriteAllText(
        $JsonPath,
        $json,
        $Utf8NoBom
    )


    [System.IO.File]::WriteAllText(
        $HtmlPath,
        $html,
        $Utf8NoBom
    )


    Write-Host ""
    Write-Host "EXPORTACION COMPLETADA" -ForegroundColor Green

    Write-Host "Puerto: $($result.Port)"
    Write-Host "Catalogo: $($result.Catalog)"
    Write-Host "Registros: $newRowCount"

    Write-Host "JSON: $JsonPath"
    Write-Host "HTML: $HtmlPath"

    Write-Log `
        "Exportacion completada. $newRowCount registros. Puerto $($result.Port). Catalogo $($result.Catalog)."

    exit 0
}
catch {

    # Ante cualquier error se conserva el ultimo
    # JSON y HTML validos.

    Write-Log `
        "Exportacion cancelada. Se conserva el ultimo JSON y HTML validos. Motivo: $($_.Exception.Message)"

    Fail `
        -Message $_.Exception.Message
}