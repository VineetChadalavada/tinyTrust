// TinyTrust -- machine timer (S1-A)
//
// REGISTERS (word offsets within the timer block)
//   0x0  MTIME     free-running counter, writable
//   0x4  MTIMECMP  compare value; the interrupt is asserted while
//                  MTIME >= MTIMECMP
//
// 32 BITS, NOT 64
// The RISC-V specification defines these as 64-bit counters. This chip
// implements 32, which wraps in about 43 seconds at 100 MHz. That is a
// documented deviation, recorded in ARCHITECTURE.md §4, and firmware has to
// handle the wrap. It is the same trade the rest of version 1 made: the
// upper half costs storage and a wider comparator for something no demo
// needs.
//
// The interrupt is a level, not a pulse, and it is deliberately not cleared
// by reading anything. It goes away when software moves MTIMECMP forward,
// which is exactly how the specification says a timer interrupt is
// acknowledged. A pulse would be lost if it arrived while interrupts were
// masked; a level cannot be.

module timer (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        sel,
    input  wire [3:2]  addr,
    input  wire        we,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,

    output wire        irq
);

    localparam [1:0] R_MTIME = 2'd0,
                     R_CMP   = 2'd1;

    reg [31:0] mtime;
    reg [31:0] mtimecmp;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mtime    <= 32'd0;
            // Out of reset the compare value is the largest possible, so the
            // interrupt is not already pending before software has had a
            // chance to set it up. Resetting it to 0 would fire immediately.
            mtimecmp <= 32'hFFFF_FFFF;
        end else begin
            if (sel && we && (addr == R_MTIME[1:0])) mtime    <= wdata;
            else                                     mtime    <= mtime + 32'd1;
            if (sel && we && (addr == R_CMP[1:0]))   mtimecmp <= wdata;
        end
    end

    assign irq = (mtime >= mtimecmp);

    always @* begin
        case (addr)
            R_MTIME[1:0]: rdata = mtime;
            R_CMP  [1:0]: rdata = mtimecmp;
            default:      rdata = 32'd0;
        endcase
    end

endmodule
