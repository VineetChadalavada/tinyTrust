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
$rtl  = "../../rtl"
$core = @("$rtl/core/core_p5.v", "$rtl/core/regfile.v", "$rtl/core/pmp.v")

$tests = @(
    @{ name = "soc_bus";  expect = "BUS PASS";  srcs = @("tb_soc_bus.v",  "$rtl/soc/soc_bus.v") }
    @{ name = "soc_ram";  expect = "RAM PASS";  srcs = @("tb_soc_ram.v",  "$rtl/soc/soc_ram.v", "../models/sram_1p_bm.v") }
    @{ name = "soc_mmio"; expect = "MMIO PASS"; srcs = @("tb_soc_mmio.v", "$rtl/soc/soc_mmio.v",
                                   "$rtl/periph/uart.v", "$rtl/periph/gpio.v", "$rtl/periph/timer.v") }
    @{ name = "soc_top";  expect = "SOC PASS";  srcs = @("tb_soc_top.v",
                                   "$rtl/soc/soc_top.v", "$rtl/soc/soc_bus.v",
                                   "$rtl/soc/soc_ram.v", "$rtl/soc/soc_mmio.v",
                                   "$rtl/periph/uart.v", "$rtl/periph/gpio.v", "$rtl/periph/timer.v",
                                   "$rtl/cache/cache.v", "../models/sram_1p_bm.v",
                                   "../../rom/bootrom.v") + $core }
)

foreach ($t in $tests) {
    Write-Host "===== $($t.name) ====="
    $args = @("-g2012", "-o", "out/tb_$($t.name).vvp") + $t.srcs
    # Capture rather than let it stream: iverilog writes warnings to stderr,
    # and with ErrorActionPreference = Stop a native command's stderr aborts
    # the script even when it compiled fine.
    $clog = & iverilog @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "COMPILE FAIL: $($t.name)"
        $clog | ForEach-Object { Write-Host "  $_" }
        $fail = 1
        continue
    }

    $out = & vvp "out/tb_$($t.name).vvp" 2>&1
    $out | Where-Object { $_ -match "PASS|FAIL|longest run|chip says" } | ForEach-Object { Write-Host "  $_" }
    # The banner is the verdict, not the exit code -- vvp exits 0 even after
    # $display'd failures (the same trap as BUG-003 and BUG-006). Each test
    # declares the exact banner it must print, so one test's success cannot
    # stand in for another's.
    if (-not ($out -match [regex]::Escape($t.expect))) {
        Write-Host "  no '$($t.expect)' banner -- treating as failure"
        $fail = 1
    }
}

if ($fail -ne 0) { Write-Host "SOC TESTS FAILED"; exit 1 }
Write-Host "SOC TESTS PASS"
exit 0
