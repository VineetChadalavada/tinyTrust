// TinyTrust — Ascon-p permutation accelerator (round-serial: 1 round/cycle)
//
// Implements the 320-bit Ascon permutation per NIST SP 800-232.
// Hardware runs only the permutation; hash/MAC/AEAD modes are sequenced in
// software (see docs/ARCHITECTURE.md D7). State is exposed as ten 32-bit
// words for MMIO access, writable/readable only while idle.
//
// Word mapping: word[2j] = x[j][31:0], word[2j+1] = x[j][63:32], j = 0..4.
// Byte/bit-order conventions between the C reference and this register view
// are handled by software (documented in fw/ascon.h once written).
//
// Round count is WARL-style: values > 12 execute as 12, 0 executes as a
// no-op (busy never asserts).

module ascon_p (
    input  wire        clk,
    input  wire        rst_n,

    // control
    input  wire        start,      // pulse; ignored while busy
    input  wire [3:0]  num_rounds, // typically 6, 8, or 12
    output reg         busy,

    // state word access (serviced only when !busy; bus enforces this)
    input  wire        we,
    input  wire [3:0]  waddr,      // 0..9
    input  wire [31:0] wdata,
    input  wire [3:0]  raddr,      // 0..9
    output wire [31:0] rdata
);

    // ------------------------------------------------------------------
    // State: five 64-bit words x0..x4
    // ------------------------------------------------------------------
    reg [63:0] x0, x1, x2, x3, x4;
    reg [3:0]  round; // current round index 0..11 (constants indexed by this)

    // ------------------------------------------------------------------
    // Round function (combinational, one full round)
    // ------------------------------------------------------------------
    function [63:0] ror64;
        input [63:0] v;
        input [5:0]  n;
        ror64 = (v >> n) | (v << (7'd64 - {1'b0, n}));
    endfunction

    // Round constant for round index i (0..11): {15-i, i} in the low byte.
    wire [7:0] rc = {(4'd15 - round), round};

    // Constant addition
    wire [63:0] a0 = x0;
    wire [63:0] a1 = x1;
    wire [63:0] a2 = x2 ^ {56'd0, rc};
    wire [63:0] a3 = x3;
    wire [63:0] a4 = x4;

    // Substitution layer (bitsliced 5-bit S-box), input mixing
    wire [63:0] s0 = a0 ^ a4;
    wire [63:0] s1 = a1;
    wire [63:0] s2 = a2 ^ a1;
    wire [63:0] s3 = a3;
    wire [63:0] s4 = a4 ^ a3;

    // Chi-like core: si ^ (~s(i+1) & s(i+2))
    wire [63:0] c0 = s0 ^ (~s1 & s2);
    wire [63:0] c1 = s1 ^ (~s2 & s3);
    wire [63:0] c2 = s2 ^ (~s3 & s4);
    wire [63:0] c3 = s3 ^ (~s4 & s0);
    wire [63:0] c4 = s4 ^ (~s0 & s1);

    // Output mixing
    wire [63:0] b0 = c0 ^ c4;
    wire [63:0] b1 = c1 ^ c0;
    wire [63:0] b2 = ~c2;
    wire [63:0] b3 = c3 ^ c2;
    wire [63:0] b4 = c4;

    // Linear diffusion layer
    wire [63:0] l0 = b0 ^ ror64(b0, 6'd19) ^ ror64(b0, 6'd28);
    wire [63:0] l1 = b1 ^ ror64(b1, 6'd61) ^ ror64(b1, 6'd39);
    wire [63:0] l2 = b2 ^ ror64(b2, 6'd1)  ^ ror64(b2, 6'd6);
    wire [63:0] l3 = b3 ^ ror64(b3, 6'd10) ^ ror64(b3, 6'd17);
    wire [63:0] l4 = b4 ^ ror64(b4, 6'd7)  ^ ror64(b4, 6'd41);

    // ------------------------------------------------------------------
    // Control + state update
    // ------------------------------------------------------------------
    wire [3:0] eff_rounds  = (num_rounds > 4'd12) ? 4'd12 : num_rounds;
    wire [3:0] start_round = 4'd12 - eff_rounds;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy  <= 1'b0;
            round <= 4'd0;
            x0 <= 64'd0; x1 <= 64'd0; x2 <= 64'd0; x3 <= 64'd0; x4 <= 64'd0;
        end else if (busy) begin
            x0 <= l0; x1 <= l1; x2 <= l2; x3 <= l3; x4 <= l4;
            if (round == 4'd11)
                busy <= 1'b0;
            else
                round <= round + 4'd1;
        end else begin
            if (start && eff_rounds != 4'd0) begin
                busy  <= 1'b1;
                round <= start_round;
            end else if (we) begin
                case (waddr)
                    4'd0: x0[31:0]  <= wdata;
                    4'd1: x0[63:32] <= wdata;
                    4'd2: x1[31:0]  <= wdata;
                    4'd3: x1[63:32] <= wdata;
                    4'd4: x2[31:0]  <= wdata;
                    4'd5: x2[63:32] <= wdata;
                    4'd6: x3[31:0]  <= wdata;
                    4'd7: x3[63:32] <= wdata;
                    4'd8: x4[31:0]  <= wdata;
                    4'd9: x4[63:32] <= wdata;
                    default: ;
                endcase
            end
        end
    end

    // Read mux (combinational; bus qualifies with !busy)
    reg [31:0] rdata_r;
    always @(*) begin
        case (raddr)
            4'd0: rdata_r = x0[31:0];
            4'd1: rdata_r = x0[63:32];
            4'd2: rdata_r = x1[31:0];
            4'd3: rdata_r = x1[63:32];
            4'd4: rdata_r = x2[31:0];
            4'd5: rdata_r = x2[63:32];
            4'd6: rdata_r = x3[31:0];
            4'd7: rdata_r = x3[63:32];
            4'd8: rdata_r = x4[31:0];
            4'd9: rdata_r = x4[63:32];
            default: rdata_r = 32'd0;
        endcase
    end
    assign rdata = rdata_r;

endmodule
