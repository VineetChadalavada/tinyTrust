# Run the core lockstep co-sim regression (Windows).
# Requires OSS CAD Suite; set $env:OSS_CAD_SUITE if not at the default path.
#
# Three legs, because they cover different things:
#   1. multicycle core, timed bus        — the v1 core, unchanged
#   2. 5-stage core, timed bus           — randomized handshake stress
#   3. 5-stage core, fast instruction    — lets the pipeline run instructions
#      fetch (+fastmem)                    back to back, which the timed model
#                                          cannot; without this leg a whole
#                                          class of pipeline states is
#                                          unreachable in sim (see BUG-005).
#   4. 5-stage core + I$/D$ (P3)         — the caches in the real fetch and
#                                          data paths, including the SRAM
#                                          macro model.
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

python cosim.py --core mc --directed --random 4 --n 1500
if ($LASTEXITCODE -ne 0) { Write-Host "COSIM FAIL: mc"; exit 1 }

python cosim.py --core p5 --directed --random 4 --n 1500
if ($LASTEXITCODE -ne 0) { Write-Host "COSIM FAIL: p5"; exit 1 }

python cosim.py --core p5 --fastmem --directed --random 4 --n 1500
if ($LASTEXITCODE -ne 0) { Write-Host "COSIM FAIL: p5 +fastmem"; exit 1 }

python cosim.py --core p5 --cache --directed --random 4 --n 1500
if ($LASTEXITCODE -ne 0) { Write-Host "COSIM FAIL: p5 +cache"; exit 1 }

exit 0
