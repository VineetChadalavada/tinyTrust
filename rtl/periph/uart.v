// TinyTrust -- UART (S1-A)
//
// 8 data bits, no parity, 1 stop bit. Transmit and receive.
//
// WHY THIS IS THE FIRST PERIPHERAL
// Without it there is no way to tell a working chip from a dead one. Every
// bring-up step after the chip comes back depends on being able to print
// something, so this is the block whose correctness matters earliest.
//
// REGISTERS (word offsets within the UART block)
//   0x0  DATA   write: queue a byte for transmission
//               read:  the received byte, and clears the received flag
//   0x4  STAT   bit 0  transmitter busy
//               bit 1  a received byte is waiting
//               bit 2  a byte arrived while one was already waiting and was
//                      lost -- sticky until STAT is read
//   0x8  DIV    clock cycles per bit, minus one
//
// The received byte is single-buffered on purpose. A FIFO is the obvious
// improvement and it is not needed here: the boot loader reads each byte
// before the next can arrive at any sane baud rate, and the overflow flag
// says so rather than hiding it. Adding depth later changes nothing outside
// this file.

module uart #(
    // 10416 is 9600 baud from a 100 MHz clock. The real value is written by
    // software at start-up; this is only what comes out of reset.
    parameter [15:0] DIV_RESET = 16'd10415
) (
    input  wire        clk,
    input  wire        rst_n,

    // register interface, driven by soc_mmio
    input  wire        sel,
    input  wire [3:2]  addr,
    input  wire        we,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,

    // pins
    input  wire        rx,
    output reg         tx
);

    localparam [1:0] R_DATA = 2'd0,
                     R_STAT = 2'd1,
                     R_DIV  = 2'd2;

    reg [15:0] div;

    // ------------------------------------------------------------------
    // Transmit
    // ------------------------------------------------------------------
    reg [15:0] tx_cnt;
    reg [3:0]  tx_bit;      // 0 = start, 1..8 = data, 9 = stop
    reg [7:0]  tx_sr;
    reg        tx_busy;

    wire tx_tick = (tx_cnt == 16'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx      <= 1'b1;        // idle high
            tx_busy <= 1'b0;
            tx_cnt  <= 16'd0;
            tx_bit  <= 4'd0;
            tx_sr   <= 8'd0;
        end else if (!tx_busy) begin
            tx <= 1'b1;
            if (sel && we && (addr == R_DATA[1:0])) begin
                tx_sr   <= wdata[7:0];
                tx_busy <= 1'b1;
                tx_bit  <= 4'd0;
                tx_cnt  <= div;
                tx      <= 1'b0;    // start bit goes out immediately
            end
        end else if (!tx_tick) begin
            tx_cnt <= tx_cnt - 16'd1;
        end else begin
            tx_cnt <= div;
            if (tx_bit == 4'd9) begin
                tx_busy <= 1'b0;    // stop bit done
                tx      <= 1'b1;
            end else begin
                tx_bit <= tx_bit + 4'd1;
                tx     <= (tx_bit == 4'd8) ? 1'b1        // stop
                                           : tx_sr[0];
                tx_sr  <= {1'b0, tx_sr[7:1]};
            end
        end
    end

    // ------------------------------------------------------------------
    // Receive
    //
    // The input is synchronised through two flip-flops before anything looks
    // at it. It comes from a pin and is asynchronous to this clock, so
    // sampling it directly would eventually latch a metastable value.
    // ------------------------------------------------------------------
    reg  [1:0] rx_sync;
    wire       rx_s = rx_sync[1];
    always @(posedge clk or negedge rst_n)
        if (!rst_n) rx_sync <= 2'b11;
        else        rx_sync <= {rx_sync[0], rx};

    reg [15:0] rx_cnt;
    reg [3:0]  rx_bit;
    reg [7:0]  rx_sr;
    reg        rx_active;
    reg [7:0]  rx_data;
    reg        rx_full;
    reg        rx_ovf;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_active <= 1'b0;
            rx_cnt    <= 16'd0;
            rx_bit    <= 4'd0;
            rx_sr     <= 8'd0;
            rx_data   <= 8'd0;
            rx_full   <= 1'b0;
            rx_ovf    <= 1'b0;
        end else begin
            // reading DATA consumes the byte
            if (sel && !we && (addr == R_DATA[1:0]))
                rx_full <= 1'b0;
            // reading STAT clears the sticky overflow flag
            if (sel && !we && (addr == R_STAT[1:0]))
                rx_ovf <= 1'b0;

            if (!rx_active) begin
                if (!rx_s) begin
                    // Start bit seen. Wait half a bit so every later sample
                    // lands in the middle of its bit rather than on an edge.
                    rx_active <= 1'b1;
                    rx_cnt    <= {1'b0, div[15:1]};
                    rx_bit    <= 4'd0;
                end
            end else if (rx_cnt != 16'd0) begin
                rx_cnt <= rx_cnt - 16'd1;
            end else begin
                rx_cnt <= div;
                if (rx_bit == 4'd0) begin
                    // mid start bit; if it went away it was noise
                    if (rx_s) rx_active <= 1'b0;
                    else      rx_bit    <= 4'd1;
                end else if (rx_bit <= 4'd8) begin
                    rx_sr  <= {rx_s, rx_sr[7:1]};
                    rx_bit <= rx_bit + 4'd1;
                end else begin
                    rx_active <= 1'b0;
                    if (rx_s) begin           // valid stop bit
                        rx_data <= rx_sr;
                        if (rx_full && !(sel && !we && (addr == R_DATA[1:0])))
                            rx_ovf <= 1'b1;
                        rx_full <= 1'b1;
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Registers
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            div <= DIV_RESET;
        else if (sel && we && (addr == R_DIV[1:0]))
            div <= wdata[15:0];
    end

    always @* begin
        case (addr)
            R_DATA[1:0]: rdata = {24'd0, rx_data};
            R_STAT[1:0]: rdata = {29'd0, rx_ovf, rx_full, tx_busy};
            R_DIV [1:0]: rdata = {16'd0, div};
            default:     rdata = 32'd0;
        endcase
    end

endmodule
