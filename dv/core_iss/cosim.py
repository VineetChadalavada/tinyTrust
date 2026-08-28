"""Lockstep co-sim runner: RTL (Icarus) vs the Python RV32E ISS.

Usage:
  python cosim.py --directed                 # all directed tests
  python cosim.py --test smoke jump          # named directed tests
  python cosim.py --random 8 --n 2000        # 8 random seeds, 2000 templates
  python cosim.py --directed --random 4      # both

Exit code 0 only if every run passes (RTL trace == ISS trace, both ended
at the TOHOST store).
"""
import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from rv32e import ISS                                    # noqa: E402
from progbuild import build_program                      # noqa: E402
import directed                                          # noqa: E402
import gen_program                                       # noqa: E402

OUT = os.path.join(HERE, "out")
RTL = [os.path.join(HERE, "tb_core.v")] + [
    os.path.join(HERE, "..", "..", "rtl", "core", f)
    for f in ("core.v", "regfile.v", "pmp.v")]


def setup_path():
    suite = os.environ.get("OSS_CAD_SUITE", r"E:\tools\oss-cad-suite")
    os.environ["PATH"] = os.path.join(suite, "bin") + os.pathsep + \
        os.path.join(suite, "lib") + os.pathsep + os.environ["PATH"]


def compile_rtl():
    os.makedirs(OUT, exist_ok=True)
    vvp = os.path.join(OUT, "sim.vvp")
    # -DRISCV_FORMAL: core.v's RVFI retire port is guarded so it stays out of
    # synthesis/P&R builds (it is 21% of core area). The lockstep check reads
    # that port, so the co-sim build must define it exactly as riscv-formal's
    # generated defines.sv does.
    subprocess.run(["iverilog", "-g2005", "-DRISCV_FORMAL", "-o", vvp] + RTL,
                   check=True)
    return vvp


def run_one(name, words, vvp, seed=1, maxlat=3, max_steps=2_000_000,
            max_cycles=20_000_000):
    hexf = os.path.join(OUT, f"{name}.hex")
    with open(hexf, "w") as f:
        f.write("".join(f"{w & 0xFFFFFFFF:08x}\n" for w in words))

    iss = ISS(words)
    iss_lines, tohost = iss.run(max_steps)
    if tohost is None:
        print(f"FAIL {name}: ISS never reached TOHOST "
              f"({len(iss_lines)} retires)")
        return False, 0

    tracef = os.path.join(OUT, f"{name}.rtl.txt")
    r = subprocess.run(
        ["vvp", vvp, f"+prog={hexf}", f"+trace={tracef}", f"+seed={seed}",
         f"+maxlat={maxlat}", f"+maxcycles={max_cycles}"],
        capture_output=True, text=True)
    if "COSIM DONE" not in r.stdout:
        tail = (r.stdout + r.stderr).strip().splitlines()[-3:]
        print(f"FAIL {name}: RTL sim did not finish cleanly: {tail}")
        return False, 0

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
            return False, 0
    if len(iss_lines) != len(rtl_lines):
        print(f"FAIL {name}: length mismatch ISS={len(iss_lines)} "
              f"RTL={len(rtl_lines)}")
        return False, 0
    print(f"PASS {name}: {len(iss_lines)} retires, tohost={tohost:#x}")
    return True, len(iss_lines)


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
    args = ap.parse_args()

    setup_path()
    vvp = compile_rtl()
    results = []

    names = list(directed.TESTS) if args.directed else args.test
    for name in names:
        body, handler = directed.TESTS[name]()
        words = build_program(body, handler)
        results.append(run_one(name, words, vvp, seed=hash(name) & 0xFFFF or 1,
                               maxlat=args.maxlat))

    for k in range(args.random):
        seed = args.seed0 + k
        words = build_program(gen_program.gen_body(seed, args.n))
        results.append(run_one(f"rand{seed}", words, vvp, seed=seed,
                               maxlat=args.maxlat))

    total, good = len(results), sum(ok for ok, _ in results)
    retired = sum(cnt for _, cnt in results)
    print(f"{good}/{total} runs passed; "
          f"{retired} retired instructions co-simulated (0 mismatches)"
          if good == total else f"{good}/{total} runs passed")
    sys.exit(0 if good == total else 1)


if __name__ == "__main__":
    main()
