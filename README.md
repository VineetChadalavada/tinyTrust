# TinyTrust

A security-hardened RV32E microcontroller SoC, designed from scratch for
tape-out on a [Tiny Tapeout](https://tinytapeout.com) SKY130 shuttle.

**Security story:** minimal hardware root of trust — M/U privilege modes with
a lean PMP, ASCON-based integrity-verified secure boot from external QSPI
flash, and fault-hardened control FSMs. Threat model and every spec deviation
are documented decisions.

## Status

- [x] Requirements — [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md)
- [x] Architecture spec — [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- [x] Calibration synthesis — [synth/calibration/REPORT.md](synth/calibration/REPORT.md)
- [ ] Core RTL (M1), privilege+PMP (M2), secure boot (M3), FPGA (M4), DV closure (M5)
- [ ] Tape-out: targeting a late-2027 Tiny Tapeout SKY shuttle

## Layout

```
docs/       requirements, architecture, (planned: threat model, vplan)
rtl/core    CPU core: regfile, pmp, (planned: datapath, control, CSRs)
rtl/periph  ascon_p permutation accelerator, (planned: uart, timer, qspi)
rtl/soc     (planned: bus, top level)
rom/        boot ROM (currently calibration stub; real ROM from bootrom.S)
fw/         demo/bring-up firmware (planned)
dv/         cocotb regressions, riscv-formal, UVM env for ascon (planned)
synth/      calibration flow + SKY130 liberty (lib not committed; see below)
tools/      generators and utilities
```

## Calibration synthesis

```
pip install yowasp-yosys
curl -L -o synth/lib/sky130_fd_sc_hd__tt_025C_1v80.lib \
  https://raw.githubusercontent.com/The-OpenROAD-Project/OpenROAD-flow-scripts/master/flow/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
python synth/calibration/run_calibration.py
```

## License

Apache-2.0. The ASCON algorithm is per NIST SP 800-232 (public domain design).
