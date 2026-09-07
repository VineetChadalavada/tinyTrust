# Run the cache formal proofs (P3, D22).
#
#   .\run.ps1                 # both caches, both legs
#   .\run.ps1 -Which i        # instruction cache only
#   .\run.ps1 -Which d        # data cache only
#   .\run.ps1 -Leg bmc        # skip the cover leg (bmc is the slow one)
#
# The property is in cache_fv.sv: the cache is transparent, i.e. a read
# returns the last value written to that address. See D22 in
# docs/RETARGET.md for why the cache is proven here rather than folded into
# the core's riscv-formal wrapper.
#
# CACHE-FV-01 has two legs and needs both:
#
#   <cache>.sby        bmc   - the assertion holds to the bound
#   <cache>_cover.sby  cover - the environment can actually reach a read of
#                              the tracked word, so the bmc pass is not
#                              vacuous. sby evaluates cover statements only
#                              in cover mode, so cache_fv.sv's cover does
#                              nothing under the bmc config; this is what
#                              runs it.
# The D$ bmc leg is NOT in the default suite: it is known not to terminate,
# for two separate measured reasons documented in the header of dcache.sby.
# The default runs what actually returns a verdict -- the I$ proof and both
# non-vacuity covers -- so a green run means something. -IncludeOpen adds it
# back for anyone working on closing it.
param([ValidateSet("both", "i", "d")][string]$Which = "both",
      [ValidateSet("both", "bmc", "cover")][string]$Leg = "both",
      [switch]$IncludeOpen)
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

$legs = switch ($Leg) {
    "bmc"   { @("") }
    "cover" { @("_cover") }
    default { @("", "_cover") }
}

# The data cache is proven by induction rather than by a bounded run, so it
# has its own pair: dcache_kind.sby and its non-vacuity witness. See the
# header of dcache_kind.sby for why the bounded route could never work.
$extra = @("dcache_kind", "dcache_kind_cover")

$jobs = @()
foreach ($t in $targets) {
    foreach ($legSuffix in $legs) {
        if ($legSuffix -eq "" -and $t -eq "dcache" -and -not $IncludeOpen) {
            Write-Host "----- skipping dcache (bmc): known not to close, see dcache.sby; -IncludeOpen to run it"
            continue
        }
        $jobs += "$t$legSuffix"
    }
}

$jobs += $extra

$fail = 0
foreach ($job in $jobs) {
    Write-Host "===== $job ====="
    sby -f "$job.sby"
    if ($LASTEXITCODE -ne 0) { $fail = 1 }
}

exit $fail
