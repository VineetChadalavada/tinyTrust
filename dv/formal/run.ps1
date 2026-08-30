# Set up and run the riscv-formal bounded checks (Windows).
#   .\run.ps1                  # everything, multicycle core
#   .\run.ps1 -Core p5         # everything, 5-stage core
#   .\run.ps1 -Filter insn_*   # subset
#   .\run.ps1 -Jobs 8
#
# -Core mc uses dv/formal/tinytrust/ (rtl/core/core.v); -Core p5 uses
# dv/formal/tinytrust_p5/ (rtl/core/core_p5.v). Each gets its own generated
# checks tree under riscv-formal/cores/, so both can be built and kept.
param([string]$Filter = "*",
      [int]$Jobs = 4,
      [ValidateSet("mc", "p5")][string]$Core = "mc")
$ErrorActionPreference = "Stop"
$suite = if ($env:OSS_CAD_SUITE) { $env:OSS_CAD_SUITE } else { "E:\tools\oss-cad-suite" }
$env:PATH = "$suite\bin;$suite\lib;" + $env:PATH

$srcDir = if ($Core -eq "p5") { "tinytrust_p5" } else { "tinytrust" }

$rf = Join-Path $PSScriptRoot "riscv-formal"
if (-not (Test-Path $rf)) {
    git clone --depth 1 https://github.com/YosysHQ/riscv-formal.git $rf
}
$coreDir = Join-Path $rf "cores\$srcDir"
New-Item -ItemType Directory -Force $coreDir | Out-Null
Copy-Item (Join-Path $PSScriptRoot "$srcDir\*") $coreDir -Force

Push-Location $coreDir
python ..\..\checks\genchecks.py
if ($LASTEXITCODE -ne 0) { Pop-Location; exit 1 }
Pop-Location

python (Join-Path $PSScriptRoot "runchecks.py") --jobs $Jobs --filter $Filter --core $Core
exit $LASTEXITCODE
