#!/usr/bin/env python3
"""TinyTrust calibration synthesis (ABC-free flow).

YoWASP Yosys cannot run ABC (silently dies in the WASI sandbox), so instead
of liberty mapping we stop at generic gate mapping:

    synth -noabc  +  simplemap  ->  only $_NOT_/$_AND_/$_OR_/$_XOR_/
                                    $_XNOR_/$_MUX_/$_DFF*_ primitives

and price each primitive with the corresponding SKY130 HD cell area taken
from the liberty file. This slightly OVERESTIMATES area versus a real
ABC/OpenLane flow (no gate sharing / complex-cell mapping), i.e. it errs on
the safe side for tile budgeting. Expect the real flow to come in ~10-30%
lower on combinational-heavy blocks.

Usage:  python run_calibration.py [--yosys CMD]
Needs:  ../lib/sky130_fd_sc_hd__tt_025C_1v80.lib
Writes: results.json and prints a summary table.
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
LIB = HERE.parent / "lib" / "sky130_fd_sc_hd__tt_025C_1v80.lib"

# TT tile: ~160 x 100 um. Usable std-cell area at ~55% placement density.
TILE_UM2 = 160.0 * 100.0
DENSITY = 0.55

BLOCKS = {
    "ascon_p": [ROOT / "rtl" / "periph" / "ascon_p.v"],
    "regfile": [ROOT / "rtl" / "core" / "regfile.v"],
    "pmp":     [ROOT / "rtl" / "core" / "pmp.v"],
    "bootrom": [ROOT / "rom" / "bootrom_stub.v"],
}

# yosys generic primitive -> SKY130 HD cell used for pricing.
# DFFs with enable are priced as plain DFF + input mux (how simplemap-level
# logic would realize them; sky130 does have enable/reset flops that a real
# flow would use, costing slightly less).
PRIM2CELL = {
    "$_NOT_":  ["inv_1"],
    "$_AND_":  ["and2_1"],
    "$_OR_":   ["or2_1"],
    "$_XOR_":  ["xor2_1"],
    "$_XNOR_": ["xnor2_1"],
    "$_NAND_": ["nand2_1"],
    "$_NOR_":  ["nor2_1"],
    "$_MUX_":  ["mux2_1"],
    "$_DFF_P_":     ["dfxtp_1"],
    "$_DFF_PN0_":   ["dfrtp_1"],
    "$_DFF_PN1_":   ["dfstp_1"],
    "$_DFFE_PP_":   ["dfxtp_1", "mux2_1"],
    "$_DFFE_PN0P_": ["dfrtp_1", "mux2_1"],
    "$_DFFE_PN1P_": ["dfstp_1", "mux2_1"],
}


def cell_area(text: str, cell: str) -> float:
    idx = text.find(f'cell ("sky130_fd_sc_hd__{cell}")')
    if idx < 0:
        raise RuntimeError(f"cell {cell} not found in liberty file")
    m = re.search(r"area\s*:\s*([\d.]+)", text[idx:idx + 40000])
    if not m:
        raise RuntimeError(f"no area for cell {cell}")
    return float(m.group(1))


def load_areas() -> dict:
    text = LIB.read_text(errors="ignore")
    cells = sorted({c for lst in PRIM2CELL.values() for c in lst})
    return {c: cell_area(text, c) for c in cells}


def synth_block(yosys: str, name: str, files: list) -> dict:
    reads = "\n".join(
        f"read_verilog {f.relative_to(ROOT).as_posix()}" for f in files)
    top = "bootrom" if name == "bootrom" else name
    script = f"""
{reads}
synth -top {top} -noabc
simplemap
opt_clean
stat
"""
    ys = HERE / f"_{name}.ys"
    ys.write_text(script)
    # YoWASP yosys runs in a WASI sandbox; run from repo root, relative paths.
    proc = subprocess.run([yosys, str(ys.relative_to(ROOT).as_posix())],
                          capture_output=True, text=True, cwd=ROOT)
    log = proc.stdout + proc.stderr
    (HERE / f"_{name}.log").write_text(log)
    if proc.returncode != 0:
        raise RuntimeError(f"yosys failed for {name}; see _{name}.log")

    # Parse cell-type counts from the LAST stat section only — `synth`
    # itself runs an internal stat pass, which must not be double-counted.
    # Yosys 0.67 stat format: "   669   $_AND_" (count first).
    idx = log.rfind(f"=== {top} ===")
    if idx < 0:
        raise RuntimeError(f"no stat output for {name}; see _{name}.log")
    counts = {}
    for m in re.finditer(r"^\s+(\d+)\s+(\$\S+)\s*$", log[idx:], re.MULTILINE):
        counts[m.group(2)] = counts.get(m.group(2), 0) + int(m.group(1))
    if not counts:
        raise RuntimeError(f"no cell counts for {name}; see _{name}.log")
    return counts


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--yosys", default="yowasp-yosys")
    args = ap.parse_args()

    if not LIB.exists():
        sys.exit(f"missing liberty file: {LIB}")
    areas = load_areas()
    ge_um2 = areas["nand2_1"] if "nand2_1" in areas else cell_area(
        LIB.read_text(errors="ignore"), "nand2_1")
    tile_capacity = TILE_UM2 * DENSITY

    results = {"nand2_area_um2": ge_um2, "tile_um2": TILE_UM2,
               "density": DENSITY, "cell_areas": areas, "blocks": {}}
    total_area = 0.0
    print(f"{'block':<10} {'area um^2':>10} {'flops':>6} {'kGE':>7} {'tiles':>6}")
    for name, files in BLOCKS.items():
        counts = synth_block(args.yosys, name, files)
        area = 0.0
        flops = 0
        unknown = {}
        for prim, n in counts.items():
            if prim in PRIM2CELL:
                area += n * sum(areas[c] for c in PRIM2CELL[prim])
                if "DFF" in prim:
                    flops += n
            elif prim.startswith("$"):
                unknown[prim] = n
        r = {"area_um2": area, "flops": flops,
             "kGE": area / ge_um2 / 1000.0,
             "tiles": area / tile_capacity,
             "prim_counts": counts, "unpriced": unknown}
        results["blocks"][name] = r
        total_area += area
        print(f"{name:<10} {area:>10.0f} {flops:>6} "
              f"{r['kGE']:>7.2f} {r['tiles']:>6.2f}")
        if unknown:
            print(f"           WARNING unpriced primitives: {unknown}")
    print(f"{'TOTAL':<10} {total_area:>10.0f} {'':>6} "
          f"{total_area/ge_um2/1000.0:>7.2f} {total_area/tile_capacity:>6.2f}")

    (HERE / "results.json").write_text(json.dumps(results, indent=2))
    print(f"\nwrote {HERE / 'results.json'}")


if __name__ == "__main__":
    main()
