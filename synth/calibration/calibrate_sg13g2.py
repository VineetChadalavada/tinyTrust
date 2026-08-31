#!/usr/bin/env python3
"""TinyTrust area calibration against IHP SG13G2 (real ABC liberty mapping).

Supersedes run_calibration.py for v2. That script exists because YoWASP Yosys
could not run ABC in its WASI sandbox, so it stopped at generic primitives
($_AND_, $_DFFE_PP_, ...) and *priced* them from a SKY130 liberty — knowingly
overestimating by 10-30% on combinational logic. Two things killed that
approach:

  1. v2 targets ihp-sg13g2, not sky130 (docs/RETARGET.md D12).
  2. A real Yosys with a working ABC is now installed (OSS CAD Suite locally,
     and the ORFS build in WSL), so blocks can be *mapped* rather than priced.

run_calibration.py is kept for the v1 record — it is the basis of the tile
budget in ARCHITECTURE.md §10 — but its numbers are also stale: it reports
regfile = 480 flops, which is RV32E, from before D18.

Usage:  python calibrate_sg13g2.py [--yosys yosys]
Needs:  ../lib/sg13g2_stdcell_typ_1p20V_25C.lib   (gitignored; copy from the
        ORFS platform dir flow/platforms/ihp-sg13g2/lib/)
Writes: results_sg13g2.json and prints a summary table.

Note `core` is measured WITHOUT -DRISCV_FORMAL, i.e. the synthesisable core
with the RVFI retire port compiled out, which is what the P&R flow sees.
"""
import argparse
import json
import os
import pathlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
LIB = HERE.parent / "lib" / "sg13g2_stdcell_typ_1p20V_25C.lib"

# Blocks to measure. `core` pulls in regfile and pmp as submodules, so its
# number already contains theirs — regfile/pmp are listed separately for the
# breakdown, not to be summed with core.
BLOCKS = {
    "core":    ("core", [ROOT / "rtl" / "core" / "core.v",
                         ROOT / "rtl" / "core" / "regfile.v",
                         ROOT / "rtl" / "core" / "pmp.v"]),
    "core_p5": ("core_p5", [ROOT / "rtl" / "core" / "core_p5.v",
                            ROOT / "rtl" / "core" / "regfile.v",
                            ROOT / "rtl" / "core" / "pmp.v"]),
    "regfile": ("regfile", [ROOT / "rtl" / "core" / "regfile.v"]),
    "pmp":     ("pmp", [ROOT / "rtl" / "core" / "pmp.v"]),
    # The caches synthesise with the SRAM macro as a blackbox, so these
    # numbers are the standard-cell half only: tag flops, comparators and the
    # refill/writeback control. The data array is the macro measured in
    # pd/results/sram_smoke/METRICS.md (150,102 um^2 = 20.68 kGE each).
    "cache_i": ("cache", [ROOT / "rtl" / "cache" / "cache.v",
                          ROOT / "rtl" / "mem" / "sram_macro_bb.v"],
                {"WRITABLE": 0}),
    "cache_d": ("cache", [ROOT / "rtl" / "cache" / "cache.v",
                          ROOT / "rtl" / "mem" / "sram_macro_bb.v"],
                {"WRITABLE": 1}),
    "ascon_p": ("ascon_p", [ROOT / "rtl" / "periph" / "ascon_p.v"]),
    "bootrom": ("bootrom", [ROOT / "rom" / "bootrom_stub.v"]),
}

SUBMODULE_OF_CORE = {"regfile", "pmp"}

# core and core_p5 are alternatives, not siblings: a top-level total takes one
# or the other. `core` is the v1 baseline the P1 numbers were taken against;
# `core_p5` is what v2 carries forward from P2 on.
CORE_VARIANTS = {"core", "core_p5"}
PERIPHERALS = ("ascon_p", "bootrom")
# caches are reported standalone; they are not part of the v1 top-level total
STANDALONE = ("cache_i", "cache_d")


def setup_path() -> None:
    """Put OSS CAD Suite on PATH (bin AND lib — yosys.exe needs both)."""
    suite = os.environ.get("OSS_CAD_SUITE", r"E:\tools\oss-cad-suite")
    if pathlib.Path(suite).is_dir():
        os.environ["PATH"] = (os.path.join(suite, "bin") + os.pathsep +
                              os.path.join(suite, "lib") + os.pathsep +
                              os.environ["PATH"])


def nand2_area(text: str) -> float:
    """1 GE = the area of sg13g2_nand2_1."""
    idx = text.find("cell (sg13g2_nand2_1)")
    if idx < 0:
        raise RuntimeError("sg13g2_nand2_1 not found in liberty file")
    m = re.search(r"area\s*:\s*([\d.]+)", text[idx:idx + 40000])
    if not m:
        raise RuntimeError("no area for sg13g2_nand2_1")
    return float(m.group(1))


def synth_block(yosys: str, name: str, top: str, files: list,
                params: dict = None) -> dict:
    reads = "\n".join(f"read_verilog {f.as_posix()}" for f in files)
    # chparam must run before hierarchy: the same module is measured at more
    # than one parameter setting (cache_i and cache_d differ only in WRITABLE).
    chp = "\n".join(f"chparam -set {k} {v} {top}"
                    for k, v in (params or {}).items())
    script = f"""
{reads}
{chp}
hierarchy -check -top {top}
synth -top {top} -flatten
dfflibmap -liberty {LIB.as_posix()}
abc -liberty {LIB.as_posix()}
setundef -zero
opt_clean -purge
stat -liberty {LIB.as_posix()}
"""
    ys = HERE / f"_sg13g2_{name}.ys"
    ys.write_text(script, encoding="utf-8")
    proc = subprocess.run([yosys, "-s", str(ys)],
                          capture_output=True, text=True)
    log = proc.stdout + proc.stderr
    (HERE / f"_sg13g2_{name}.log").write_text(log, encoding="utf-8")
    if proc.returncode != 0:
        raise RuntimeError(f"yosys failed for {name}; see _sg13g2_{name}.log")

    m = re.search(r"Chip area for (?:top )?module '\\" + top +
                  r"':\s*([\d.]+)", log)
    if not m:
        raise RuntimeError(f"no chip area for {name}; see _sg13g2_{name}.log")
    area = float(m.group(1))

    seq = re.search(r"sequential elements:\s*([\d.]+)", log)
    seq_area = float(seq.group(1)) if seq else 0.0

    # Cell histogram from the final stat block only. With -liberty, stat
    # prints "count  area  name" — the area column must be skipped or the
    # name never matches and every flop count comes back 0.
    idx = log.rfind("=== ")
    cells = {}
    for cm in re.finditer(r"^\s+(\d+)\s+[\d.]+(?:E[+-]?\d+)?\s+(sg13g2_\S+)",
                          log[idx:], re.M):
        cells[cm.group(2)] = cells.get(cm.group(2), 0) + int(cm.group(1))
    flops = sum(n for c, n in cells.items() if "_df" in c or "_sdf" in c)

    return {"area_um2": area, "seq_area_um2": seq_area, "flops": flops,
            "cells": cells}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--yosys", default="yosys")
    args = ap.parse_args()

    setup_path()
    if not LIB.exists():
        sys.exit(f"missing liberty file: {LIB}\n"
                 "copy it from the ORFS platform: "
                 "flow/platforms/ihp-sg13g2/lib/")

    ge = nand2_area(LIB.read_text(errors="ignore"))
    results = {"platform": "ihp-sg13g2", "liberty": LIB.name,
               "nand2_area_um2": ge, "blocks": {}}

    print(f"1 GE = sg13g2_nand2_1 = {ge} um^2\n")
    print(f"{'block':<10} {'area um^2':>11} {'kGE':>8} {'flops':>7} "
          f"{'seq %':>7}")
    for name, spec in BLOCKS.items():
        top, files = spec[0], spec[1]
        params = spec[2] if len(spec) > 2 else None
        r = synth_block(args.yosys, name, top, files, params)
        r["kGE"] = r["area_um2"] / ge / 1000.0
        r["submodule_of_core"] = name in SUBMODULE_OF_CORE
        results["blocks"][name] = r
        seq_pct = (100.0 * r["seq_area_um2"] / r["area_um2"]
                   if r["area_um2"] else 0.0)
        tag = ("  (in core)" if name in SUBMODULE_OF_CORE
               else "  (+ SRAM macro)" if name in STANDALONE else "")
        print(f"{name:<10} {r['area_um2']:>11.0f} {r['kGE']:>8.2f} "
              f"{r['flops']:>7} {seq_pct:>6.1f}%{tag}")

    # Top-level total: one core variant + the blocks that are not inside it.
    periph = sum(results["blocks"][n]["area_um2"] for n in PERIPHERALS)
    results["totals"] = {}
    for variant in sorted(CORE_VARIANTS):
        total = results["blocks"][variant]["area_um2"] + periph
        results["totals"][variant] = {"um2": total, "kGE": total / ge / 1000.0}
        print(f"{'TOTAL':<10} {total:>11.0f} {total/ge/1000.0:>8.2f}"
              f"        (with {variant} + ascon_p + bootrom)")
    # keep the v1/P1 key so downstream readers of results_sg13g2.json still work
    results["total_top_level_um2"] = results["totals"]["core"]["um2"]
    results["total_top_level_kGE"] = results["totals"]["core"]["kGE"]

    (HERE / "results_sg13g2.json").write_text(
        json.dumps(results, indent=2), encoding="utf-8")
    print(f"\nwrote {HERE / 'results_sg13g2.json'}")


if __name__ == "__main__":
    main()
