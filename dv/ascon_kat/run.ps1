# Run the ascon_p KAT regression (Windows).
# Requires OSS CAD Suite; set $env:OSS_CAD_SUITE if not at the default path.
$ErrorActionPreference = "Stop"
$suite = if ($env:OSS_CAD_SUITE) { $env:OSS_CAD_SUITE } else { "E:\tools\oss-cad-suite" }
$env:PATH = "$suite\bin;$suite\lib;" + $env:PATH

Set-Location $PSScriptRoot
python gen_vectors.py
iverilog -g2005 -o sim.vvp tb_ascon_p.v ..\..\rtl\periph\ascon_p.v
if ($LASTEXITCODE -ne 0) { exit 1 }
$out = vvp sim.vvp
$out
if ($out -match "ALL TESTS PASSED") { exit 0 } else { exit 1 }
