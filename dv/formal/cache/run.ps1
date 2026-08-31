# Run the cache formal proofs (P3, D22).
#
#   .\run.ps1            # both caches
#   .\run.ps1 -Which i   # instruction cache only
#   .\run.ps1 -Which d   # data cache only
#
# The property is in cache_fv.sv: the cache is transparent, i.e. a read
# returns the last value written to that address. See D22 in
# docs/RETARGET.md for why the cache is proven here rather than folded into
# the core's riscv-formal wrapper.
param([ValidateSet("both", "i", "d")][string]$Which = "both")
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$suite = if ($env:OSS_CAD_SUITE) { $env:OSS_CAD_SUITE } else { "E:\tools\oss-cad-suite" }
$env:PATH = "$suite\bin;$suite\lib;" + $env:PATH

# Same launcher-pair shim as dv/formal/runchecks.py: oss-cad-suite ships
# yosys-smtbmc as <tool>.exe.exe + <tool>.exe-script.py, which cmd cannot
# resolve under the bare name.
$shim = Join-Path $PSScriptRoot "..\toolshim"
if (-not (Get-Command yosys-smtbmc -ErrorAction SilentlyContinue)) {
    New-Item -ItemType Directory -Force $shim | Out-Null
    foreach ($t in @("yosys-smtbmc", "yosys-witness")) {
        $launcher = Join-Path $suite "bin\$t.exe.exe"
        if (Test-Path $launcher) {
            Set-Content -Path (Join-Path $shim "$t.bat") -Encoding ascii `
                -Value "@echo off`r`n`"$launcher`" %*"
        }
    }
}
$env:PATH = (Resolve-Path $shim).Path + ";" + $env:PATH

$targets = switch ($Which) {
    "i"    { @("icache") }
    "d"    { @("dcache") }
    default { @("icache", "dcache") }
}

$fail = 0
foreach ($t in $targets) {
    Write-Host "===== $t ====="
    sby -f "$t.sby"
    if ($LASTEXITCODE -ne 0) { $fail = 1 }
}
exit $fail
