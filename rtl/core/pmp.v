// TinyTrust — lean PMP: 4 entries, NAPOT + OFF only, 1 KiB grain (D6)
//
// Documented deviations from the RISC-V privileged spec (all WARL-legal):
//   - pmpcfg.A accepts only OFF (00) and NAPOT (11); TOR/NA4 write as OFF.
//   - Grain G = 7: pmpaddr[6:0] read as ones when A=NAPOT, so the minimum
//     region is 1 KiB. Stored bits per entry: pmpaddr[29:7] (23 bits).
//   - Physical addresses are 32-bit; pmpaddr[31:30] are read-as-zero.
//
// Check semantics (spec-compliant):
//   - Lowest-numbered matching entry decides.
//   - M-mode: allowed unless a matching entry is locked and denies.
//   - U-mode: no matching entry => deny.
//   - Locked entries ignore CSR writes (both cfg byte and pmpaddr) until reset.

module pmp (
    input  wire        clk,
    input  wire        rst_n,

    // CSR write port (CSR read mux lives in the core's CSR file)
    input  wire        csr_we,
    input  wire [2:0]  csr_addr,   // 0: pmpcfg0, 1..4: pmpaddr0..3
    input  wire [31:0] csr_wdata,
    output wire [31:0] csr_rdata_cfg,
    output wire [31:0] csr_rdata_addr0,
    output wire [31:0] csr_rdata_addr1,
    output wire [31:0] csr_rdata_addr2,
    output wire [31:0] csr_rdata_addr3,

    // access check (combinational)
    input  wire [31:2] chk_addr,   // word-aligned physical address
    input  wire        chk_r,
    input  wire        chk_w,
    input  wire        chk_x,      // exactly one of r/w/x is set
    input  wire        priv_m,     // 1 = M-mode, 0 = U-mode
    output wire        allow
);

    // ------------------------------------------------------------------
    // CSR state: per entry cfg = {L, A(1b: napot), X, W, R}, addr[29:7]
    // A is stored as one bit (0=OFF, 1=NAPOT) and expanded on read.
    // ------------------------------------------------------------------
    reg [4:0]  cfg  [0:3];   // {L, A, X, W, R}
    reg [29:7] addr [0:3];

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 4; i = i + 1) begin
                cfg[i]  <= 5'd0;
                addr[i] <= 23'd0;
            end
        end else if (csr_we) begin
            if (csr_addr == 3'd0) begin
                // pmpcfg0: four cfg bytes; locked entries ignore their byte.
                for (i = 0; i < 4; i = i + 1) begin
                    if (!cfg[i][4]) begin
                        cfg[i][4]   <= csr_wdata[i*8+7];                    // L
                        cfg[i][3]   <= (csr_wdata[i*8+4 +: 2] == 2'b11);    // A: NAPOT else OFF
                        cfg[i][2:0] <= csr_wdata[i*8 +: 3];                 // X, W, R
                    end
                end
            end else if (csr_addr >= 3'd1 && csr_addr <= 3'd4) begin
                if (!cfg[csr_addr - 3'd1][4])
                    addr[csr_addr - 3'd1] <= csr_wdata[29:7];
            end
        end
    end

    // CSR read views
    genvar g;
    wire [7:0] cfg_byte [0:3];
    generate
        for (g = 0; g < 4; g = g + 1) begin : g_cfgrd
            assign cfg_byte[g] = {cfg[g][4], 2'b00,
                                  cfg[g][3] ? 2'b11 : 2'b00,
                                  cfg[g][2:0]};
        end
    endgenerate
    assign csr_rdata_cfg   = {cfg_byte[3], cfg_byte[2], cfg_byte[1], cfg_byte[0]};
    assign csr_rdata_addr0 = {2'b00, addr[0], {7{cfg[0][3]}}};
    assign csr_rdata_addr1 = {2'b00, addr[1], {7{cfg[1][3]}}};
    assign csr_rdata_addr2 = {2'b00, addr[2], {7{cfg[2][3]}}};
    assign csr_rdata_addr3 = {2'b00, addr[3], {7{cfg[3][3]}}};

    // ------------------------------------------------------------------
    // Match + permission per entry
    // ------------------------------------------------------------------
    // pmpaddr semantics: pmpaddr = phys_addr[33:2]; with G=7 the low 7 bits
    // are ones, so the effective NAPOT field is {addr[29:7], 7'h7F}.
    // mask = pa ^ (pa + 1) covers the trailing-ones run plus its boundary bit.
    wire        match [0:3];
    wire        perm  [0:3];
    generate
        for (g = 0; g < 4; g = g + 1) begin : g_match
            wire [29:0] pa   = {addr[g], 7'h7F};
            wire [29:0] mask = pa ^ (pa + 30'd1);
            assign match[g] = cfg[g][3] &&
                              (((chk_addr[31:2] ^ pa) & ~mask) == 30'd0);
            assign perm[g]  = (chk_r & cfg[g][0]) |
                              (chk_w & cfg[g][1]) |
                              (chk_x & cfg[g][2]);
        end
    endgenerate

    // Priority: lowest-numbered matching entry decides.
    wire hit     = match[0] | match[1] | match[2] | match[3];
    wire [4:0] win = match[0] ? cfg[0] :
                     match[1] ? cfg[1] :
                     match[2] ? cfg[2] : cfg[3];
    wire win_perm  = match[0] ? perm[0] :
                     match[1] ? perm[1] :
                     match[2] ? perm[2] : perm[3];

    // M-mode: constrained only by locked matching entries.
    // U-mode: must hit a matching entry with permission.
    assign allow = priv_m ? (!hit || !win[4] || win_perm)
                          : (hit && win_perm);

endmodule
