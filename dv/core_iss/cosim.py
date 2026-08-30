"""Lockstep co-sim runner: RTL (Icarus) vs the Python RV32I ISS.

Usage:
  python cosim.py --directed                 # all directed tests
  python cosim.py --test smoke jump          # named directed tests
  python cosim.py --random 8 --n 2000        # 8 random seeds, 2000 templates
  python cosim.py --directed --random 4      # both
  python cosim.py --core p5 --directed       # 5-stage core instead of mc
  python cosim.py --core both --directed     # both, plus the CPI comparison

Both cores implement the same architecture and are checked against the same
ISS trace, so --core only selects which RTL is compiled in. Every run also
reports cycles and CPI; --core both runs the identical program set through
each core and prints the P2 comparison (docs/RETARGET.md milestone P2).

Exit code 0 only if every run passes (RTL trace == ISS trace, both ended
at the TOHOST store).
"""
import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from rv32e import ISS                                    # noqa: E402
from progbuild import build_program                      # noqa: E402
import directed                                          # noqa: E402
import gen_program                                       # noqa: E402

OUT = os.path.join(HERE, "out")
RTLDIR = os.path.join(HERE, "..", "..", "rtl", "core")
CORE_SRC = {"mc": "core.v", "p5": "core_p5.v"}


def setup_path():
    suite = os.environ.get("OSS_CAD_SUITE", r"E:\tools\oss-cad-suite")
    os.environ["PATH"] = os.path.join(suite, "bin") + os.pathsep + \
        os.path.join(suite, "lib") + os.pathsep + os.environ["PATH"]


def compile_rtl(core="mc"):
    os.makedirs(OUT, exist_ok=True)
    vvp = os.path.join(OUT, f"sim_{core}.vvp")
    src = [os.path.join(HERE, "tb_core.v")] + [
        os.path.join(RTLDIR, f)
        for f in (CORE_SRC[core], "regfile.v", "pmp.v")]
    # -DRISCV_FORMAL: the RVFI retire port is guarded so it stays out of
    # synthesis/P&R builds (it is 21% of core area). The lockstep check reads
    # that port, so the co-sim build must define it exactly as riscv-formal's
    # generated defines.sv does.
    # -DCORE_P5 selects the 5-stage DUT and its bus arbiter inside tb_core.v.
    defines = ["-DRISCV_FORMAL"] + (["-DCORE_P5"] if core == "p5" else [])
    subprocess.run(["iverilog", "-g2005"] + defines + ["-o", vvp] + src,
                   check=True)
    return vvp


def run_one(name, words, vvp, seed=1, maxlat=3, max_steps=2_000_000,
            max_cycles=20_000_000, core="mc", fastmem=0):
    hexf = os.path.join(OUT, f"{name}.hex")
    with open(hexf, "w") as f:
        f.write("".join(f"{w & 0xFFFFFFFF:08x}\n" for w in words))

    iss = ISS(words)
    iss_lines, tohost = iss.run(max_steps)
    if tohost is None:
        print(f"FAIL {name}: ISS never reached TOHOST "
              f"({len(iss_lines)} retires)")
        return False, 0, 0

    tracef = os.path.join(OUT, f"{name}.{core}.rtl.txt")
    r = subprocess.run(
        ["vvp", vvp, f"+prog={hexf}", f"+trace={tracef}", f"+seed={seed}",
         f"+maxlat={maxlat}", f"+maxcycles={max_cycles}",
         f"+fastmem={fastmem}"],
        capture_output=True, text=True)
    if "COSIM DONE" not in r.stdout:
        tail = (r.stdout + r.stderr).strip().splitlines()[-3:]
        print(f"FAIL {name}: RTL sim did not finish cleanly: {tail}")
        return False, 0, 0
    m = re.search(r"COSIM DONE .*cycles=(\d+)", r.stdout)
    cycles = int(m.group(1)) if m else 0

    with open(tracef) as f:
        rtl_lines = [l.strip() for l in f if l.strip()]

    n = min(len(iss_lines), len(rtl_lines))
    for i in range(n):
        if iss_lines[i] != rtl_lines[i]:
            print(f"FAIL {name}: first mismatch at retire {i}")
            print(f"  fields:  order pc insn trap mode intr rs1a rs1d rs2a"
                  f" rs2d rda rdd pcw mema rmask wmask memr memw")
            print(f"  ISS: {iss_lines[i]}")
            print(f"  RTL: {rtl_lines[i]}")
            for j in range(max(0, i - 2), i):
                print(f"  ctx: {iss_lines[j]}")
            with open(os.path.join(OUT, f"{name}.iss.txt"), "w") as f:
                f.write("".join(l + "\n" for l in iss_lines))
            return False, 0, 0
    if len(iss_lines) != len(rtl_lines):
        print(f"FAIL {name}: length mismatch ISS={len(iss_lines)} "
              f"RTL={len(rtl_lines)}")
        with open(os.path.join(OUT, f"{name}.iss.txt"), "w") as f:
            f.write("".join(l + "\n" for l in iss_lines))
        return False, 0, 0
    cpi = cycles / len(iss_lines) if iss_lines else 0
    print(f"PASS {name}: {len(iss_lines)} retires, tohost={tohost:#x}, "
          f"{cycles} cycles, CPI {cpi:.2f}")
    return True, len(iss_lines), cycles


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--directed", action="store_true")
    ap.add_argument("--test", nargs="*", default=[])
    ap.add_argument("--random", type=int, default=0,
                    help="number of random seeds to run")
    ap.add_argument("--seed0", type=int, default=1)
    ap.add_argument("--n", type=int, default=2000,
                    help="templates per random program")
    ap.add_argument("--maxlat", type=int, default=3)
    ap.add_argument("--fastmem", action="store_true",
                    help="zero-wait-state memory (ready is combinational)."
                         " Lets the pipeline run instructions back to back,"
                         " which the timed model cannot: see tb_core.v and"
                         " BUG-005.")
    ap.add_argument("--core", choices=("mc", "p5", "both"), default="mc",
                    help="mc = multicycle core.v, p5 = 5-stage core_p5.v")
    args = ap.parse_args()

    setup_path()

    # Build the program set once so both cores see byte-identical stimulus.
    programs = []
    names = list(directed.TESTS) if args.directed else args.test
    for name in names:
        body, handler = directed.TESTS[name]()
        programs.append((name, build_program(body, handler),
                         hash(name) & 0xFFFF or 1))
    for k in range(args.random):
        seed = args.seed0 + k
        programs.append((f"rand{seed}",
                         build_program(gen_program.gen_body(seed, args.n)),
                         seed))

    cores = ("mc", "p5") if args.core == "both" else (args.core,)
    summary = {}
    rc = 0
    for core in cores:
        if len(cores) > 1:
            print(f"--- core={core} ---")
        vvp = compile_rtl(core)
        results = []
        for name, words, seed in programs:
            results.append(run_one(name, words, vvp, seed=seed,
                                   maxlat=args.maxlat, core=core,
                                   fastmem=1 if args.fastmem else 0))
        total = len(results)
        good = sum(ok for ok, _, _ in results)
        retired = sum(cnt for ok, cnt, _ in results if ok)
        cycles = sum(cyc for ok, _, cyc in results if ok)
        summary[core] = (retired, cycles)
        print(f"{good}/{total} runs passed; "
              f"{retired} retired instructions co-simulated (0 mismatches)"
              if good == total else f"{good}/{total} runs passed")
        if good != total:
            rc = 1

    if len(cores) > 1 and rc == 0:
        print("\n--- CPI (P2 exit criterion) ---")
        for core in cores:
            n, c = summary[core]
            print(f"  {core:3s}: {c:>9d} cycles / {n:>7d} instructions"
                  f" = CPI {c / n:.3f}")
        nm, cm = summary["mc"]
        np_, cp = summary["p5"]
        print(f"  speedup (mc CPI / p5 CPI): {(cm / nm) / (cp / np_):.3f}x")
    sys.exit(rc)


if __name__ == "__main__":
    main()
