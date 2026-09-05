# Run the SoC-level block tests (S1-A).
#
#   .\run.ps1
#
# Currently the bus: routing, unmapped-address faulting, the one-slave-at-a-
# time invariant, and arbiter fairness under sustained contention.
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$suite = if ($env:OSS_CAD_SUITE) { $env:OSS_CAD_SUITE } else { "E:\tools\oss-cad-suite" }
$env:PATH = "$suite\bin;$suite\lib;" + $env:PATH

New-Item -ItemType Directory -Force out | Out-Null

$fail = 0
$tests = @(
    @{ name = "soc_bus"; srcs = @("tb_soc_bus.v", "../../rtl/soc/soc_bus.v") }
)

foreach ($t in $tests) {
    Write-Host "===== $($t.name) ====="
    $args = @("-g2012", "-o", "out/tb_$($t.name).vvp") + $t.srcs
    & iverilog @args
    if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAIL: $($t.name)"; $fail = 1; continue }

    $out = & vvp "out/tb_$($t.name).vvp" 2>&1
    $out | Where-Object { $_ -match "PASS|FAIL|longest run" } | ForEach-Object { Write-Host "  $_" }
    # The banner is the verdict, not the exit code -- vvp exits 0 even after
    # $display'd failures (the same trap as BUG-003 and BUG-006).
    if (-not ($out -match "BUS PASS|SOC PASS")) { $fail = 1 }
}

if ($fail -ne 0) { Write-Host "SOC TESTS FAILED"; exit 1 }
Write-Host "SOC TESTS PASS"
exit 0
