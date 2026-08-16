# Set up and run the riscv-formal bounded checks (Windows).
#   .\run.ps1                  # everything
#   .\run.ps1 -Filter insn_*   # subset
#   .\run.ps1 -Jobs 8
param([string]$Filter = "*", [int]$Jobs = 4)
$ErrorActionPreference = "Stop"
$suite = if ($env:OSS_CAD_SUITE) { $env:OSS_CAD_SUITE } else { "E:\tools\oss-cad-suite" }
$env:PATH = "$suite\bin;$suite\lib;" + $env:PATH

$rf = Join-Path $PSScriptRoot "riscv-formal"
if (-not (Test-Path $rf)) {
    git clone --depth 1 https://github.com/YosysHQ/riscv-formal.git $rf
}
$coreDir = Join-Path $rf "cores\tinytrust"
New-Item -ItemType Directory -Force $coreDir | Out-Null
Copy-Item (Join-Path $PSScriptRoot "tinytrust\*") $coreDir -Force

Push-Location $coreDir
python ..\..\checks\genchecks.py
if ($LASTEXITCODE -ne 0) { Pop-Location; exit 1 }
Pop-Location

python (Join-Path $PSScriptRoot "runchecks.py") --jobs $Jobs --filter $Filter
exit $LASTEXITCODE
