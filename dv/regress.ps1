# TinyTrust local regression (vplan §6): must pass before every commit
# touching rtl/ or rom/. CI runs the full matrix; this is the fast gate.
$ErrorActionPreference = "Stop"

& "$PSScriptRoot\ascon_kat\run.ps1"
if ($LASTEXITCODE -ne 0) { Write-Host "REGRESS FAIL: ascon_kat"; exit 1 }

& "$PSScriptRoot\core_iss\run.ps1"
if ($LASTEXITCODE -ne 0) { Write-Host "REGRESS FAIL: core_iss"; exit 1 }

Write-Host "REGRESS PASS"
exit 0
