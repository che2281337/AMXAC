# Compiles scripting/*.sma into compiled/*.amxx using the AMXX compiler in tools/amxx.
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$pc   = Join-Path $root "tools\amxx\addons\amxmodx\scripting\amxxpc.exe"
$inc1 = Join-Path $root "tools\amxx\addons\amxmodx\scripting\include"
$inc2 = Join-Path $root "scripting\include"
$out  = Join-Path $root "compiled"

New-Item -ItemType Directory -Force $out | Out-Null
$failed = 0
foreach ($f in Get-ChildItem (Join-Path $root "scripting\*.sma")) {
    $log = & $pc $f.FullName "-i$inc1" "-i$inc2" "-o$(Join-Path $out ($f.BaseName + '.amxx'))"
    $issues = $log | Select-String -Pattern "error|warning"
    if ($LASTEXITCODE -ne 0) { $failed++ }
    if ($issues) { Write-Output "== $($f.Name)"; $issues | ForEach-Object { Write-Output "   $_" } }
    else { Write-Output "ok $($f.Name)" }
}
if ($failed) { Write-Output "$failed plugin(s) failed"; exit 1 }
