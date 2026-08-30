"""Run the generated riscv-formal SBY checks for the TinyTrust core.

Assumes run.ps1 (or an equivalent) has already cloned riscv-formal, copied
dv/formal/tinytrust/ into cores/tinytrust/, and run genchecks.py there.

  python runchecks.py [--jobs N] [--filter GLOB] [--list]
"""
import argparse
import concurrent.futures
import fnmatch
import glob
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CORE_DIR = {"mc": "tinytrust", "p5": "tinytrust_p5"}
# set by main() from --core; run.ps1 has already generated the matching tree
CHECKS = os.path.join(HERE, "riscv-formal", "cores", "tinytrust", "checks")

# Checks that smtbmc/boolector (the genchecks default) cannot close in
# reasonable time, routed to pure-SAT bounded model checking instead. The reg
# check does one monolithic BMC query at CHECK_CYCLE with the register file
# modelled as an array; every SMT/BTOR engine drowns in read-over-write lemma
# refinement at depth >~30, while abc-bmc3 on a memory_map'd (array-expanded)
# netlist solves it with plain incremental SAT. genchecks only exposes a
# *global* solver and its `bmc3` mode needs a separate gates.il build we
# bypass, so we patch the generated .sby here instead. See dv/formal/README.md
# and tinytrust/checks.cfg (reg depth note).
HEAVY_ENGINE = {"reg": "abc bmc3"}


def patch_heavy_engines():
    """Rewrite generated .sby files for HEAVY_ENGINE checks: swap the engine,
    memory_map the design so arrays become flops, and drop `skip` (abc's BMC
    checks every frame; the check's assertion is already gated to CHECK_CYCLE,
    so earlier frames are trivially passing)."""
    for sby in glob.glob(os.path.join(CHECKS, "*.sby")):
        base = os.path.basename(sby)[:-4]
        engine = next((e for k, e in HEAVY_ENGINE.items()
                       if base == k or base.startswith(k + "_")), None)
        if engine is None:
            continue
        txt = open(sby).read()
        if "\n" + engine in txt:
            continue  # already patched
        txt = re.sub(r"(?m)^smtbmc\s+\S+.*$", engine, txt)
        txt = re.sub(r"(?m)^\s*skip\s+\d+\s*$\n?", "", txt)
        txt = txt.replace(
            "prep -flatten -nordff -top rvfi_testbench",
            "prep -flatten -nordff -top rvfi_testbench\nmemory_map\nopt -fast")
        open(sby, "w").write(txt)


def setup_path():
    suite = os.environ.get("OSS_CAD_SUITE", r"E:\tools\oss-cad-suite")
    os.environ["PATH"] = os.path.join(suite, "bin") + os.pathsep + \
        os.path.join(suite, "lib") + os.pathsep + os.environ["PATH"]
    # oss-cad-suite ships some helpers as a setuptools launcher pair
    # (<tool>.exe.exe + <tool>.exe-script.py), which cmd cannot resolve under
    # the bare name. Shim them with .bat files, leaving the suite untouched.
    # (python3 resolves via suite\lib, already on PATH.)
    #   yosys-smtbmc — the default BMC engine
    #   yosys-witness — converts abc's .aiw counterexample into a .yw trace.
    #     Without it an abc-bmc3 check that finds a real counterexample dies
    #     with "COMMAND NOT FOUND" and is reported ERROR instead of FAIL, so
    #     the verdict is right but the trace needed to debug it is missing.
    import shutil
    shim = os.path.join(HERE, "toolshim")
    for tool in ("yosys-smtbmc", "yosys-witness"):
        if shutil.which(tool) is not None:
            continue
        launcher = os.path.join(suite, "bin", f"{tool}.exe.exe")
        if os.path.exists(launcher):
            os.makedirs(shim, exist_ok=True)
            with open(os.path.join(shim, f"{tool}.bat"), "w") as f:
                f.write(f'@echo off\r\n"{launcher}" %*\r\n')
            os.environ["PATH"] = shim + os.pathsep + os.environ["PATH"]


def run_check(sby):
    name = os.path.splitext(os.path.basename(sby))[0]
    t0 = time.time()
    r = subprocess.run(["sby", "-f", os.path.basename(sby)],
                       cwd=CHECKS, capture_output=True, text=True)
    dt = time.time() - t0
    out = r.stdout + r.stderr
    # sby prints "DONE (STATUS, rc=N)" with STATUS in PASS/FAIL/ERROR/... — that
    # line is the source of truth. Do NOT infer PASS from the exit code: the
    # generated .sby carry `expect pass,fail`, so sby exits 0 even on a real
    # counterexample (a FAIL is an "expected" outcome to it). A missing DONE
    # line (tool crash / kill) stays ERROR.
    status = "ERROR"
    for line in out.splitlines():
        if "] DONE (" in line:
            status = line.split("DONE (")[1].split(",")[0]
    return name, status, dt, out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--filter", default="*")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--core", choices=("mc", "p5"), default="mc",
                    help="mc = core.v (cores/tinytrust), "
                         "p5 = core_p5.v (cores/tinytrust_p5)")
    args = ap.parse_args()

    global CHECKS
    CHECKS = os.path.join(HERE, "riscv-formal", "cores",
                          CORE_DIR[args.core], "checks")
    if not os.path.isdir(CHECKS):
        print(f"no generated checks at {CHECKS} — run "
              f"run.ps1 -Core {args.core} first")
        sys.exit(2)

    setup_path()
    patch_heavy_engines()
    sbys = sorted(glob.glob(os.path.join(CHECKS, "*.sby")))
    pats = args.filter.split(",")
    sbys = [s for s in sbys
            if any(fnmatch.fnmatch(os.path.basename(s)[:-4], p)
                   for p in pats)]
    if args.list:
        for s in sbys:
            print(os.path.basename(s)[:-4])
        return
    if not sbys:
        print("no checks match filter", args.filter)
        sys.exit(2)

    fails = []
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as ex:
        for name, status, dt, out in ex.map(run_check, sbys):
            print(f"{status} {name} ({dt:.1f}s)", flush=True)
            if status != "PASS":
                fails.append(name)
                tail = [l for l in out.splitlines() if l.strip()][-6:]
                for l in tail:
                    print("   |", l)
    print(f"{len(sbys) - len(fails)}/{len(sbys)} checks passed")
    if fails:
        print("failed:", " ".join(fails))
        print(f"counterexample traces: {CHECKS}\\<check>\\engine_0\\")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
