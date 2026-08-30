// TinyTrust — riscv-formal wrapper for the 5-stage core (vplan dv/formal, L2)
//
// Same proof environment as cores/tinytrust (the multicycle core), retargeted
// to core_p5's split instruction/data ports. Everything that is assumed here
// is assumed for the same reason as there; the differences are noted inline.
//
// Environment model:
//  - two independent valid/ready channels (instruction, data), unconstrained
//    rdata, each with a fairness assumption (ready within 2 cycles of valid)
//    so bounded checks spend their depth on instructions rather than stalls.
//    The multicycle wrapper needs one such counter because it has one port;
//    the pipeline can have a fetch and a data access outstanding at once.
//  - bus faults tied off (assume !imem_fault, !dmem_fault): the base
//    riscv-formal insn models have no notion of a bus access fault, so an
//    injected fault makes the core take a *correct* access-fault trap that
//    the spec scores as a mismatch. Tying them off restricts the proof to the
//    fault-free memory space (where the insn/reg/pc checks verify data/addr/
//    PC); the fault -> precise-trap path is a sim testpoint (dv/core_iss
//    ls_fault + fetch_fault directed tests, ISS lockstep on cause 1/5/7)
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
//  - no rv32e assumption: the core is RV32I (docs/RETARGET.md D18), so the
//    checks run over the full register space with no ISA-shaping assumption
//  - interrupts tied off (PRV-INT-* are M2 testpoints)
//  - UAR-FSM-01 formal half: the fsm_fault alarm must never fire without
//    injected faults — asserted here, so every check proves it at its depth

module rvfi_wrapper (
    input clock,
    input reset,
    `RVFI_OUTPUTS
);
    (* keep *) wire        imem_valid;
    (* keep *) wire [31:0] imem_addr;
    (* keep *) wire        dmem_valid;
    (* keep *) wire [31:0] dmem_addr;
    (* keep *) wire [31:0] dmem_wdata;
    (* keep *) wire [3:0]  dmem_wstrb;
    (* keep *) wire        fsm_fault;

    (* keep *) `rvformal_rand_reg        imem_ready;
    (* keep *) `rvformal_rand_reg [31:0] imem_rdata;
    (* keep *) `rvformal_rand_reg        imem_fault;
    (* keep *) `rvformal_rand_reg        dmem_ready;
    (* keep *) `rvformal_rand_reg [31:0] dmem_rdata;
    (* keep *) `rvformal_rand_reg        dmem_fault;

    core_p5 uut (
        .clk          (clock),
        .rst_n        (!reset),
        .imem_valid   (imem_valid),
        .imem_addr    (imem_addr),
        .imem_ready   (imem_ready),
        .imem_rdata   (imem_rdata),
        .imem_fault   (imem_fault),
        .dmem_valid   (dmem_valid),
        .dmem_addr    (dmem_addr),
        .dmem_wdata   (dmem_wdata),
        .dmem_wstrb   (dmem_wstrb),
        .dmem_ready   (dmem_ready),
        .dmem_rdata   (dmem_rdata),
        .dmem_fault   (dmem_fault),
        .irq_timer    (1'b0),
        .irq_external (1'b0),
        .fsm_fault    (fsm_fault),
        `RVFI_CONN
    );

    // bus fairness, per channel: a transaction completes within 2 cycles
    reg [1:0] istall_cnt, dstall_cnt;
    always @(posedge clock) begin
        if (reset) begin
            istall_cnt <= 2'd0;
            dstall_cnt <= 2'd0;
        end else begin
            if (imem_valid && !imem_ready)
                istall_cnt <= istall_cnt + 2'd1;
            else
                istall_cnt <= 2'd0;
            if (dmem_valid && !dmem_ready)
                dstall_cnt <= dstall_cnt + 2'd1;
            else
                dstall_cnt <= 2'd0;
        end
    end
    always @* assume (istall_cnt < 2'd2);
    always @* assume (dstall_cnt < 2'd2);

    // bus faults are out of the base insn checks' scope (see header): tie off
    always @* assume (!imem_fault);
    always @* assume (!dmem_fault);

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

    always @(posedge clock)
        if (!reset && imem_valid && imem_ready && !imem_fault) begin
            assume (mmode_safe(imem_rdata));
        end

    // UAR-FSM-01: the privilege shadow agrees with the privilege state
    always @* if (!reset) assert (!fsm_fault);

endmodule
