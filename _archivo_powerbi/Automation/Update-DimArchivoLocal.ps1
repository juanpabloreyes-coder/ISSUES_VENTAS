param([string]$Reason="Revisión programada",[switch]$Silent)
$ErrorActionPreference="Stop"
$Root="C:\Users\Usuario\DC\ACCDocs\GCPEASA\VENTAS GCP\Project Files"
$Here=Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot=Split-Path -Parent $Here
$Definition=Join-Path $RepositoryRoot "ISSUES_VENTAS.SemanticModel\definition"
$Target=Join-Path $Definition "tables\DimArchivoLocal.tmdl"
$State=Join-Path $Here "filemap-state.json";$Log=Join-Path $Here "automation.log";$Backup=Join-Path $Here "DimArchivoLocal.last-good.tmdl"
$Utf8=[Text.UTF8Encoding]::new($false)
function Log($m){[IO.File]::AppendAllText($Log,"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  FILEMAP  $m$([Environment]::NewLine)",$Utf8)}
function Save($h){[IO.File]::WriteAllText($State,($h|ConvertTo-Json -Depth 4),$Utf8)}
function Notify($title,$message){if($Silent){return};try{Add-Type -AssemblyName System.Windows.Forms;Add-Type -AssemblyName System.Drawing;$i=[Windows.Forms.NotifyIcon]::new();$i.Icon=[Drawing.SystemIcons]::Information;$i.Visible=$true;$i.BalloonTipTitle=$title;$i.BalloonTipText=$message;$i.ShowBalloonTip(8000);Start-Sleep -Milliseconds 1200;$i.Dispose()}catch{}}
function Hash($rows){$s=($rows|Sort-Object DocumentUrn|ForEach-Object{"$($_.DocumentUrn)|$($_.NombreArchivo)|$($_.ProyectoConcurso)"})-join "`n";$sha=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($sha.ComputeHash($Utf8.GetBytes($s)))).Replace('-','').ToLower()}finally{$sha.Dispose()}}
if(-not('DimArchivoReparseReader'-as[type])){Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;using Microsoft.Win32.SafeHandles;using System.Text;using System.Text.RegularExpressions;
public static class DimArchivoReparseReader{[DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]static extern SafeFileHandle CreateFile(string n,uint a,uint s,IntPtr x,uint c,uint f,IntPtr t);[DllImport("kernel32.dll",SetLastError=true)]static extern bool DeviceIoControl(SafeFileHandle h,uint c,IntPtr i,int iz,byte[] o,int oz,out int r,IntPtr v);public static string Urn(string p){using(var h=CreateFile(p,0,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero)){if(h.IsInvalid)return null;var b=new byte[65536];int r;if(!DeviceIoControl(h,0x900A8,IntPtr.Zero,0,b,b.Length,out r,IntPtr.Zero))return null;var s=new StringBuilder();for(int i=0;i<r;i++){byte z=b[i];if(z>=33&&z<=126)s.Append((char)z);}var m=Regex.Match(s.ToString(),@"urn:adsk\.wipprod:dm\.lineage:[A-Za-z0-9_-]+");return m.Success?m.Value:null;}}}
'@}
try{
 Log "Inicio: $Reason";if(-not(Test-Path $Root)){throw "Desktop Connector no tiene disponible: $Root"}
 $map=@{};foreach($f in Get-ChildItem -LiteralPath $Root -Recurse -File){$u=[DimArchivoReparseReader]::Urn($f.FullName);if(!$u){continue};$rel=$f.FullName.Substring($Root.Length).TrimStart([char]92);$project=$rel.Split([char]92)[0];$map[$u]=[pscustomobject]@{DocumentUrn=$u;NombreArchivo=$f.Name;ProyectoConcurso=$project}}
 $rows=@($map.Values);$fp=Hash $rows;$old=if(Test-Path $State){Get-Content -Raw $State|ConvertFrom-Json}else{$null};$now=(Get-Date).ToString('o')
 if($old -and $old.Fingerprint -eq $fp){Save @{Status='Actualizado';Pending=$false;FileCount=$rows.Count;Fingerprint=$fp;LastChecked=$now;LastUpdated=$old.LastUpdated;LastReason=$old.LastReason;LastError=$null};Log "Sin cambios: $($rows.Count) archivos.";exit 0}
 if(@(Get-Process PBIDesktop -ErrorAction SilentlyContinue).Count -gt 0){Save @{Status='Esperando a que Power BI cierre el archivo';Pending=$true;FileCount=$rows.Count;PendingFingerprint=$fp;Fingerprint=if($old){$old.Fingerprint}else{$null};LastChecked=$now;LastError=$null};Log "Cambio pendiente: Power BI está usando el archivo.";exit 10}
 $esc={param($x) ([string]$x).Replace('"','""')};$lines=$rows|Sort-Object DocumentUrn|ForEach-Object{'                    {"'+(& $esc $_.DocumentUrn)+'", "'+(& $esc $_.NombreArchivo)+'", "'+(& $esc $_.ProyectoConcurso)+'"}'}
 $body=$lines-join ",$([Environment]::NewLine)";$text=@"
table DimArchivoLocal
	lineageTag: 6f4ed035-d7c6-4efa-8cfb-9cbcf17125f7

	column DocumentUrn
		dataType: string
		lineageTag: 75c3e03f-bda9-4ca8-a48f-d03f62311478
		summarizeBy: none
		sourceColumn: DocumentUrn

	column NombreArchivo
		dataType: string
		lineageTag: 42f687d1-1a9f-4cfa-a017-ec1ca6c00659
		summarizeBy: none
		sourceColumn: NombreArchivo

	column ProyectoConcurso
		dataType: string
		lineageTag: 01f15f1d-754e-4e28-a2a1-38487ef45267
		summarizeBy: none
		sourceColumn: ProyectoConcurso

	partition DimArchivoLocal = m
		mode: import
		queryGroup: VENTAS
		source =
				let
				    LocalFileMap = #table(type table [DocumentUrn = nullable text, NombreArchivo = nullable text, ProyectoConcurso = nullable text], {
$body
				    }),
				    Output = Table.Distinct(LocalFileMap, {"DocumentUrn"})
				in Output

	annotation PBI_ResultType = Table
"@
 if(Test-Path $Target){Copy-Item $Target $Backup -Force};[IO.File]::WriteAllText($Target,$text,$Utf8)
 [void][Reflection.Assembly]::LoadFrom('C:\Program Files\Microsoft Power BI Desktop\bin\Microsoft.PowerBI.Amo.dll');$db=[Microsoft.AnalysisServices.TmdlSerializer]::DeserializeDatabaseFromFolder($Definition);$v=$db.Model.Validate();if($v.ContainsErrors){throw 'La validación del modelo devolvió errores.'}
 Save @{Status='Actualizado';Pending=$false;FileCount=$rows.Count;Fingerprint=$fp;LastChecked=$now;LastUpdated=$now;LastReason=$Reason;LastError=$null};Log "Actualización completada: $($rows.Count) archivos.";Notify 'DimArchivoLocal actualizado' "$($rows.Count) archivos mapeados.";exit 0
}catch{
 $message=$_.Exception.Message
 try{if(Test-Path $Backup){Copy-Item $Backup $Target -Force -ErrorAction Stop}}catch{Log "ADVERTENCIA: no se pudo restaurar el respaldo: $($_.Exception.Message)"}
 Save @{Status='Error';Pending=$false;FileCount=0;LastChecked=(Get-Date).ToString('o');LastError=$message}
 Log "ERROR: $message"
 exit 1
}
