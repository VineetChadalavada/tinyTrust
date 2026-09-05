// TinyTrust -- peripheral window (S1-A)
//
// A bus slave that decodes the peripheral region and routes to the blocks
// inside it. The offsets are the ones ARCHITECTURE.md §4 fixed, so firmware
// written against that map works unchanged:
//
//   0x00  UART    DATA, STAT, DIV
//   0x10  GPIO    OUT, IN
//   0x20  TIMER   MTIME, MTIMECMP
//   0x40  SEC     STATUS, ALERT
//
// Peripherals answer in the cycle they are asked. There is nothing here that
// needs to wait -- every register is a flip-flop or a wire -- so `ready` is
// just `valid`, and a write lands on the clock edge that completes the
// transfer.
//
// An access to an offset with no block behind it **faults** rather than
// reading zero. Reading zero from a register that does not exist is the kind
// of thing that turns into an afternoon of debugging firmware; a trap points
// straight at the offending instruction.
//
// SEC is implemented here rather than in its own file because it is two
// registers. ALERT is write-one-to-set and **software cannot clear it** --
// only a reset can. That is the whole point of it: firmware that notices
// something wrong can raise an alarm that survives whatever happens next,
// including the firmware itself being subverted.

module soc_mmio #(
    parameter GPIO_W = 4,
    parameter [15:0] UART_DIV_RESET = 16'd10415
) (
    input  wire              clk,
    input  wire              rst_n,

    // bus slave
    input  wire              s_valid,
    input  wire [31:0]       s_addr,
    input  wire [31:0]       s_wdata,
    input  wire [3:0]        s_wstrb,
    output wire              s_ready,
    output reg  [31:0]       s_rdata,
    output wire              s_fault,

    // pins
    input  wire              uart_rx,
    output wire              uart_tx,
    output wire [GPIO_W-1:0] gpio_out,
    input  wire [GPIO_W-1:0] gpio_in,
    output wire              sec_alert,

    // to the processor
    output wire              irq_timer,

    // from the processor's fault-detection logic
    input  wire              fsm_fault,
    input  wire [1:0]        straps
);

    localparam [3:0] B_UART  = 4'h0,
                     B_GPIO  = 4'h1,
                     B_TIMER = 4'h2,
                     B_SEC   = 4'h4;

    wire [3:0] blk  = s_addr[7:4];
    wire [3:2] roff = s_addr[3:2];
    wire       we   = s_valid && (s_wstrb != 4'd0);

    wire sel_uart  = s_valid && (blk == B_UART);
    wire sel_gpio  = s_valid && (blk == B_GPIO);
    wire sel_timer = s_valid && (blk == B_TIMER);
    wire sel_sec   = s_valid && (blk == B_SEC);

    wire mapped = sel_uart | sel_gpio | sel_timer | sel_sec;

    wire [31:0] rd_uart, rd_gpio, rd_timer;

    uart #(.DIV_RESET(UART_DIV_RESET)) u_uart (
        .clk(clk), .rst_n(rst_n),
        .sel(sel_uart), .addr(roff), .we(we && sel_uart),
        .wdata(s_wdata), .rdata(rd_uart),
        .rx(uart_rx), .tx(uart_tx)
    );

    gpio #(.W(GPIO_W)) u_gpio (
        .clk(clk), .rst_n(rst_n),
        .sel(sel_gpio), .addr(roff), .we(we && sel_gpio),
        .wdata(s_wdata), .rdata(rd_gpio),
        .gpio_out(gpio_out), .gpio_in(gpio_in)
    );

    timer u_timer (
        .clk(clk), .rst_n(rst_n),
        .sel(sel_timer), .addr(roff), .we(we && sel_timer),
        .wdata(s_wdata), .rdata(rd_timer),
        .irq(irq_timer)
    );

    // ------------------------------------------------------------------
    // SEC: status and a one-way alert
    // ------------------------------------------------------------------
    localparam [1:0] R_STATUS = 2'd0,
                     R_ALERT  = 2'd1;

    reg alert_q;
    reg fault_seen;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            alert_q    <= 1'b0;
            fault_seen <= 1'b0;
        end else begin
            // sticky: set by hardware detecting a corrupted state, and never
            // cleared except by reset
            if (fsm_fault) fault_seen <= 1'b1;
            // write-one-to-set, and there is deliberately no path that clears
            if (sel_sec && we && (roff == R_ALERT[1:0]) && s_wdata[0])
                alert_q <= 1'b1;
        end
    end

    assign sec_alert = alert_q | fault_seen;

    reg [31:0] rd_sec;
    always @* begin
        case (roff)
            R_STATUS[1:0]: rd_sec = {28'd0, fault_seen, alert_q, straps};
            R_ALERT [1:0]: rd_sec = {31'd0, alert_q};
            default:       rd_sec = 32'd0;
        endcase
    end

    // ------------------------------------------------------------------
    // Response
    // ------------------------------------------------------------------
    always @* begin
        case (blk)
            B_UART:  s_rdata = rd_uart;
            B_GPIO:  s_rdata = rd_gpio;
            B_TIMER: s_rdata = rd_timer;
            B_SEC:   s_rdata = rd_sec;
            default: s_rdata = 32'd0;
        endcase
    end

    assign s_ready = s_valid;
    assign s_fault = s_valid && !mapped;

endmodule
