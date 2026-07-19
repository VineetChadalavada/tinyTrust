# Run the core lockstep co-sim regression (Windows).
# Requires OSS CAD Suite; set $env:OSS_CAD_SUITE if not at the default path.
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
python cosim.py --directed --random 4 --n 1500
exit $LASTEXITCODE
