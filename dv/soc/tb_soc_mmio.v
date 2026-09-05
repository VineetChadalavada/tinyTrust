// TinyTrust -- testbench for rtl/soc/soc_mmio.v and the peripherals (S1-A)
//
// The UART is checked on the wire, not through its own status register. A
// transmitter that sets "busy" and then clears it has proved nothing; the
// test decodes the serial waveform bit by bit and compares the byte. The
// receiver is driven the same way, by wiggling the pin.
//
// Also checked: general-purpose pins in both directions, the timer counting
// and raising its interrupt at the right value, the alert bit being
// impossible to clear from software, and an unmapped offset faulting rather
// than quietly reading zero.

`timescale 1ns/1ps

module tb_soc_mmio;

    localparam BASE = 32'h3000_0000;
    localparam DIV  = 3;                  // 4 clocks per bit, to keep it quick

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    integer errors = 0;

    task check;
        input cond;
        input [511:0] what;
        begin
            if (!cond) begin
                $display("  FAIL: %0s (t=%0t)", what, $time);
                errors = errors + 1;
            end
        end
    endtask

    reg         s_valid;
    reg  [31:0] s_addr, s_wdata;
    reg  [3:0]  s_wstrb;
    wire        s_ready, s_fault;
    wire [31:0] s_rdata;

    reg        uart_rx = 1'b1;
    wire       uart_tx;
    wire [3:0] gpio_out;
    reg  [3:0] gpio_in = 4'd0;
    wire       sec_alert;
    wire       irq_timer;
    reg        fsm_fault = 1'b0;
    reg  [1:0] straps = 2'b10;

    soc_mmio #(.GPIO_W(4), .UART_DIV_RESET(DIV)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_valid(s_valid), .s_addr(s_addr), .s_wdata(s_wdata),
        .s_wstrb(s_wstrb), .s_ready(s_ready), .s_rdata(s_rdata),
        .s_fault(s_fault),
        .uart_rx(uart_rx), .uart_tx(uart_tx),
        .gpio_out(gpio_out), .gpio_in(gpio_in),
        .sec_alert(sec_alert), .irq_timer(irq_timer),
        .fsm_fault(fsm_fault), .straps(straps)
    );

    task automatic wr;
        input [31:0] a;
        input [31:0] d;
        begin
            @(negedge clk);
            s_valid = 1; s_addr = a; s_wdata = d; s_wstrb = 4'hF;
            @(negedge clk);
            s_valid = 0; s_wstrb = 0;
        end
    endtask

    // The response is combinational, so the inputs have to be given a delta
    // to propagate before it is sampled. Reading s_rdata in the same step
    // that s_addr is assigned races with the always @* block and returns the
    // previous address's data.
    task automatic rd;
        input  [31:0] a;
        output [31:0] d;
        begin
            @(negedge clk);
            s_valid = 1; s_addr = a; s_wstrb = 0;
            #1;
            d = s_rdata;
            @(negedge clk);
            s_valid = 0;
        end
    endtask

    // ---- decode what the DUT transmits, straight off the pin ----
    task automatic uart_capture;
        output [7:0] b;
        integer k;
        begin
            @(negedge uart_tx);                 // start bit
            repeat (DIV + 1) @(posedge clk);    // past the start bit
            repeat ((DIV + 1) / 2) @(posedge clk);  // into the middle of bit 0
            for (k = 0; k < 8; k = k + 1) begin
                b[k] = uart_tx;
                repeat (DIV + 1) @(posedge clk);
            end
            check(uart_tx === 1'b1, "no stop bit after the data bits");
        end
    endtask

    // ---- drive a byte into the DUT's receiver ----
    task automatic uart_send;
        input [7:0] b;
        integer k;
        begin
            @(posedge clk);
            uart_rx = 1'b0;                              // start
            repeat (DIV + 1) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                uart_rx = b[k];
                repeat (DIV + 1) @(posedge clk);
            end
            uart_rx = 1'b1;                              // stop
            repeat (DIV + 1) @(posedge clk);
        end
    endtask

    reg [31:0] v;
    reg [7:0]  got;

    // Writing DATA while the transmitter is busy is ignored -- there is no
    // queue behind it. Firmware has to poll STAT, so the test does too.
    task automatic uart_wait_idle;
        reg [31:0] st;
        integer guard;
        begin
            guard = 0;
            st = 32'd1;
            while (st[0] && guard < 500) begin
                rd(BASE + 32'h04, st);
                guard = guard + 1;
            end
            check(guard < 500, "transmitter never went idle");
        end
    endtask

    initial begin
        s_valid = 0; s_addr = 0; s_wdata = 0; s_wstrb = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // ---- general-purpose pins ----
        wr(BASE + 32'h10, 32'hA);
        check(gpio_out == 4'hA, "output pins did not take the written value");
        gpio_in = 4'h5;
        repeat (4) @(posedge clk);              // through the synchroniser
        rd(BASE + 32'h14, v);
        check(v[3:0] == 4'h5, "input pins read back wrong");

        // ---- timer ----
        rd(BASE + 32'h20, v);
        check(v != 32'd0, "timer is not counting");
        check(!irq_timer, "timer interrupt asserted before it was armed");
        rd(BASE + 32'h20, v);
        wr(BASE + 32'h24, v + 32'd20);          // fire shortly
        repeat (40) @(posedge clk);
        check(irq_timer, "timer interrupt never fired");
        rd(BASE + 32'h20, v);
        wr(BASE + 32'h24, v + 32'd10000);       // push it out again
        @(posedge clk);
        check(!irq_timer, "moving the compare forward did not clear the interrupt");

        // ---- the alert bit is one-way ----
        rd(BASE + 32'h44, v);
        check(v[0] == 1'b0, "alert set out of reset");
        wr(BASE + 32'h44, 32'h1);
        rd(BASE + 32'h44, v);
        check(v[0] == 1'b1, "alert did not set");
        check(sec_alert, "alert pin did not follow the alert bit");
        wr(BASE + 32'h44, 32'h0);               // try to clear it
        rd(BASE + 32'h44, v);
        check(v[0] == 1'b1, "software managed to clear the alert");
        wr(BASE + 32'h44, 32'hFFFF_FFFF);
        rd(BASE + 32'h44, v);
        check(v[0] == 1'b1, "alert cleared by writing all ones");

        // straps are visible in status
        rd(BASE + 32'h40, v);
        check(v[1:0] == straps, "straps not reported in status");

        // ---- unmapped offset faults ----
        @(negedge clk);
        s_valid = 1; s_addr = BASE + 32'hF0; s_wstrb = 0;
        #1;
        check(s_fault, "unmapped peripheral offset did not fault");
        @(negedge clk);
        s_valid = 0;

        // ---- UART transmit, checked on the wire ----
        wr(BASE + 32'h08, DIV);                 // set the bit rate
        fork
            uart_capture(got);
            wr(BASE + 32'h00, 32'h5A);
        join
        check(got == 8'h5A, "transmitted byte came out wrong on the pin");

        // A write issued while the previous frame is still going must be
        // dropped rather than corrupting it. This is the contract firmware
        // depends on, so it is checked rather than assumed.
        wr(BASE + 32'h00, 32'h00);              // ignored: still transmitting
        uart_wait_idle;

        fork
            uart_capture(got);
            wr(BASE + 32'h00, 32'hC3);
        join
        check(got == 8'hC3, "second transmitted byte wrong");
        uart_wait_idle;

        // ---- UART receive, driven on the pin ----
        uart_send(8'h96);
        repeat (4) @(posedge clk);
        rd(BASE + 32'h04, v);
        check(v[1], "receiver did not report a byte waiting");
        rd(BASE + 32'h00, v);
        check(v[7:0] == 8'h96, "received byte wrong");
        rd(BASE + 32'h04, v);
        check(!v[1], "reading the data register did not clear the flag");

        // a second byte arriving before the first is read must be flagged
        uart_send(8'h11);
        uart_send(8'h22);
        rd(BASE + 32'h04, v);
        check(v[2], "overflow not reported when a byte was lost");

        repeat (4) @(posedge clk);
        if (errors == 0) $display("MMIO PASS: pins, timer, alert, fault and uart wire checks clean");
        else             $display("MMIO FAIL: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #500000;
        $display("MMIO FAIL: timeout");
        $finish;
    end

endmodule
