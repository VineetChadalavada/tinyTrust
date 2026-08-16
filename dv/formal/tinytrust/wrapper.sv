// TinyTrust — riscv-formal wrapper (vplan dv/formal, layer L2)
//
// Environment model:
//  - single valid/ready bus, unconstrained rdata, with a fairness assumption
//    (ready within 2 cycles of valid) so bounded checks spend their depth on
//    instructions rather than bus stalls
//  - bus_fault tied off (assume !bus_fault): the base riscv-formal insn
//    models have no notion of a bus access fault, so an injected fault makes
//    the core take a *correct* access-fault trap that the spec scores as a
//    mismatch. Tying it off restricts the proof to the fault-free memory
//    space (where the insn/reg/pc checks verify data/addr/PC); the
//    fault -> precise-trap path is a sim testpoint (dv/core_iss ls_fault +
//    fetch_fault directed tests, ISS lockstep on cause 1/5/7)
//  - PMP + privilege access control kept permissive (mmode_safe fetch
//    assumption): the base insn models assume an ideal unrestricted memory, so
//    a load/store/fetch that a locked PMP entry (in M-mode) or U-mode-with-no-
//    entry *correctly* denies becomes an access-fault trap the spec cannot
//    predict -> mismatch. The core boots M-mode with PMP OFF (allow==1 for all
//    accesses) and can only leave that state via mret or a pmpcfg/pmpaddr
//    write, so forbidding those two fetched instructions keeps every access
//    permitted by construction (yosys read_verilog has no hierarchical refs,
//    so we constrain the fetch stream rather than the internal allow wire).
//    PMP allow/deny and privilege faults are verified in sim (vplan §3.2/§3.3
//    PMP-*/PRV-* directed tests + co-sim)
//  - RV32E per vplan §9: riscv-formal has no first-class rv32e, so fetched
//    instructions are assumed never to name x16..x31 in a field that is an
//    architectural register (checks run as rv32i over the restricted
//    space); the trap-on-x16+ behavior itself is verified in sim
//    (dv/core_iss "rve" directed test + random bombs)
//  - interrupts tied off (PRV-INT-* are M2 testpoints)
//  - UAR-FSM-01 formal half: the fsm_fault alarm must never fire without
//    injected faults — asserted here, so every check proves it at its depth

module rvfi_wrapper (
    input clock,
    input reset,
    `RVFI_OUTPUTS
);
    (* keep *) wire        bus_valid;
    (* keep *) wire [31:0] bus_addr;
    (* keep *) wire [31:0] bus_wdata;
    (* keep *) wire [3:0]  bus_wstrb;
    (* keep *) wire        bus_is_fetch;
    (* keep *) wire        fsm_fault;
    (* keep *) `rvformal_rand_reg        bus_ready;
    (* keep *) `rvformal_rand_reg [31:0] bus_rdata;
    (* keep *) `rvformal_rand_reg        bus_fault;

    core uut (
        .clk          (clock),
        .rst_n        (!reset),
        .bus_valid    (bus_valid),
        .bus_addr     (bus_addr),
        .bus_wdata    (bus_wdata),
        .bus_wstrb    (bus_wstrb),
        .bus_is_fetch (bus_is_fetch),
        .bus_ready    (bus_ready),
        .bus_rdata    (bus_rdata),
        .bus_fault    (bus_fault),
        .irq_timer    (1'b0),
        .irq_external (1'b0),
        .fsm_fault    (fsm_fault),
        `RVFI_CONN
    );

    // bus fairness: a transaction completes within 2 cycles
    reg [1:0] stall_cnt;
    always @(posedge clock) begin
        if (reset)
            stall_cnt <= 2'd0;
        else if (bus_valid && !bus_ready)
            stall_cnt <= stall_cnt + 2'd1;
        else
            stall_cnt <= 2'd0;
    end
    always @* assume (stall_cnt < 2'd2);

    // bus faults are out of the base insn checks' scope (see header): tie off
    always @* assume (!bus_fault);

    // PMP/privilege deny is out of the base insn checks' scope (see header):
    // keep every access permitted so the core takes no PMP/U-mode access fault
    // the base ISA spec cannot predict. The access decision (pmp.v `allow`) is
    // a core-internal wire, and yosys read_verilog has no hierarchical refs, so
    // we cannot assume on it directly. Instead we keep it 1 *by construction*
    // at the fetch input (mmode_safe below): from reset the core is M-mode with
    // PMP OFF, where allow == 1 for every access; it can only leave that state
    // by (a) mret -> U-mode, or (b) writing a locked/denying pmpcfg entry, both
    // of which are single fetched instructions we forbid.
    function automatic mmode_safe(input [31:0] i);
        reg is_sys, touches_pmp_csr, is_mret;
        begin
            is_sys = (i[6:0] == 7'b1110011);
            // any CSR op (funct3 != 000/100) targeting pmpcfg0 / pmpaddr0..3
            touches_pmp_csr = is_sys && (i[13:12] != 2'b00)
                && (i[31:20] == 12'h3A0
                    || (i[31:20] >= 12'h3B0 && i[31:20] <= 12'h3B3));
            is_mret = (i == 32'h30200073);
            mmode_safe = !touches_pmp_csr && !is_mret;
        end
    endfunction

    // NOTE (docs/RETARGET.md D18): the `rv32e_ok` fetch assumption that used to
    // live here is GONE. riscv-formal has no first-class rv32e profile, so the
    // checks ran as rv32i with an assumption that fetched instructions never
    // name x16..x31 in a field that is architecturally a register — sound, but
    // it restricted the verified space and had to be argued for. The core is
    // now RV32I, so the checks run over the full register space with no
    // ISA-shaping assumption at all. This is a strict increase in coverage.

    always @(posedge clock)
        if (!reset && bus_valid && bus_is_fetch && bus_ready && !bus_fault) begin
            assume (mmode_safe(bus_rdata));
        end

    // UAR-FSM-01: control state stays one-hot, privilege shadow agrees
    always @* if (!reset) assert (!fsm_fault);

endmodule
