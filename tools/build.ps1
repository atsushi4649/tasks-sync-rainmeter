# Builds dist\TasksSync_<version>.rmskin from the TasksSync skin folder.
# Usage: powershell -ExecutionPolicy Bypass -File tools\build.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
$root = Split-Path $PSScriptRoot -Parent
$skin = Join-Path $root 'TasksSync'
$ini = [IO.File]::ReadAllText((Join-Path $skin 'TasksSync.ini'))
if ($ini -notmatch '(?m)^Version=(.+)$') { throw 'Version not found in [Metadata]' }
$version = $matches[1].Trim()
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
$out = Join-Path $dist "TasksSync_$version.rmskin"
if (Test-Path $out) { Remove-Item $out }

$rmskinIni = @"
[rmskin]
Name=Tasks Sync
Author=atsushi4649
Version=$version
MinimumRainmeter=4.4.0
MinimumWindows=10.0
LoadType=Skin
Load=TasksSync\TasksSync.ini
VariableFiles=TasksSync\@Resources\Variables.inc
"@

# safety: personal files must never be packaged
$deny = '^(client_secret.*\.json|credentials\.json|token\.dat|state\.json|State\.inc|Tasks\.inc|input\.ini)$'

$ms = New-Object IO.MemoryStream
$zip = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
$e = $zip.CreateEntry('RMSKIN.ini')
$w = New-Object IO.StreamWriter($e.Open(), (New-Object Text.UnicodeEncoding($false, $true)))
$w.Write($rmskinIni.Replace("`r`n", "`n").Replace("`n", "`r`n")); $w.Close()
foreach ($f in Get-ChildItem $skin -Recurse -File) {
    if ($f.Name -match $deny -or $f.FullName -match '\\Data\\') { throw "Refusing to package personal file: $($f.FullName)" }
    $rel = $f.FullName.Substring($skin.Length + 1).Replace('\', '/')
    $entry = $zip.CreateEntry("Skins/TasksSync/$rel")
    $s = $entry.Open(); $b = [IO.File]::ReadAllBytes($f.FullName); $s.Write($b, 0, $b.Length); $s.Close()
}
foreach ($extra in 'README.md', 'LICENSE') {
    $entry = $zip.CreateEntry("Skins/TasksSync/$extra")
    $s = $entry.Open(); $b = [IO.File]::ReadAllBytes((Join-Path $root $extra)); $s.Write($b, 0, $b.Length); $s.Close()
}
$zip.Dispose()

# .rmskin = zip + 8-byte zip size + "\0RMSKIN\0"
$bytes = $ms.ToArray()
$fs = [IO.File]::Create($out)
$fs.Write($bytes, 0, $bytes.Length)
$fs.Write([BitConverter]::GetBytes([int64]$bytes.Length), 0, 8)
$foot = [byte[]](0) + [Text.Encoding]::ASCII.GetBytes('RMSKIN') + [byte[]](0)
$fs.Write($foot, 0, $foot.Length)
$fs.Close()
Write-Host "Built $out"
