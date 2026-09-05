// TinyTrust -- whole-chip smoke test (S1-A)
//
// The testbench is the host at the other end of the serial cable. It waits
// for the chip to say hello, sends it a program, and checks the chip runs it.
//
//   chip -> host   'T'   the ROM is alive and the serial port transmits
//   host -> chip   length, then the program bytes
//   chip -> host   'G'   the loader finished and is about to hand over
//   chip           drives the output pins from the loaded program
//   chip -> host   'K'   the loaded program is running from main memory
//
// Passing this exercises every block at once and in the right order: the
// processor fetching from ROM through the instruction cache, the bus
// arbitrating between the two caches, the serial port in both directions,
// main memory taking the loader's writes through the uncached window, the
// instruction cache then fetching those same bytes through the cached
// window, and the peripherals responding to the loaded program.
//
// It is a smoke test, not a verification suite: it says the chip is wired up
// correctly, not that the processor is correct. That is what the
// co-simulation and the proofs are for, and they run against the processor
// on its own.

`timescale 1ns/1ps

module tb_soc_top;

    localparam DIV     = 3;         // 4 clocks per bit
    localparam BIT_CLK = DIV + 1;

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

    reg        uart_rx = 1'b1;
    wire       uart_tx;
    wire [3:0] gpio_out;
    reg  [3:0] gpio_in = 4'd0;
    wire       sec_alert;
    reg  [1:0] straps = 2'b00;

    soc_top #(.USE_MACRO(0), .N_RAM_MACRO(4), .UART_DIV_RESET(DIV)) dut (
        .clk(clk), .rst_n(rst_n),
        .uart_rx(uart_rx), .uart_tx(uart_tx),
        .gpio_out(gpio_out), .gpio_in(gpio_in),
        .sec_alert(sec_alert), .straps(straps)
    );

    // ------------------------------------------------------------------
    // Host receiver: runs the whole time so nothing is missed
    // ------------------------------------------------------------------
    reg [7:0]  rx_buf [0:15];
    integer    rx_n = 0;

    initial begin
        : receiver
        forever begin
            @(negedge uart_tx);
            repeat (BIT_CLK) @(posedge clk);            // past the start bit
            repeat (BIT_CLK / 2) @(posedge clk);        // into the middle
            begin : one_byte
                integer k;
                reg [7:0] b;
                for (k = 0; k < 8; k = k + 1) begin
                    b[k] = uart_tx;
                    repeat (BIT_CLK) @(posedge clk);
                end
                rx_buf[rx_n] = b;
                rx_n = rx_n + 1;
                $display("  chip says '%0s' (0x%02X) at t=%0t", b, b, $time);
            end
        end
    end

    // ------------------------------------------------------------------
    // Host transmitter
    // ------------------------------------------------------------------
    task automatic host_send;
        input [7:0] b;
        integer k;
        begin
            @(posedge clk);
            uart_rx = 1'b0;
            repeat (BIT_CLK) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                uart_rx = b[k];
                repeat (BIT_CLK) @(posedge clk);
            end
            uart_rx = 1'b1;
            repeat (BIT_CLK) @(posedge clk);
        end
    endtask

    task automatic wait_bytes;
        input integer n;
        input integer limit;
        integer guard;
        begin
            guard = 0;
            while ((rx_n < n) && (guard < limit)) begin
                @(posedge clk);
                guard = guard + 1;
            end
            check(rx_n >= n, "chip did not send the expected byte in time");
        end
    endtask

    // ------------------------------------------------------------------
    localparam NPROG = 6;               // instructions in hello.hex

    reg [31:0] prog [0:NPROG-1];
    integer    nprog, i, j;
    reg [31:0] w;

    initial begin
        $readmemh("hello.hex", prog);
        nprog = NPROG;

        repeat (8) @(posedge clk);
        rst_n = 1;

        // ---- the chip should introduce itself ----
        wait_bytes(1, 20000);
        check(rx_buf[0] == "T", "first byte from the chip was not 'T'");

        // ---- send the length, little-endian ----
        host_send((nprog * 4)       & 8'hFF);
        host_send((nprog * 4) >>  8 & 8'hFF);
        host_send((nprog * 4) >> 16 & 8'hFF);
        host_send((nprog * 4) >> 24 & 8'hFF);

        // ---- send the program, little-endian per word ----
        for (i = 0; i < nprog; i = i + 1) begin
            w = prog[i];
            for (j = 0; j < 4; j = j + 1)
                host_send(w[j*8 +: 8]);
        end

        // ---- the loader should hand over ----
        wait_bytes(2, 40000);
        check(rx_buf[1] == "G", "second byte from the chip was not 'G'");

        // ---- and the loaded program should run ----
        wait_bytes(3, 40000);
        check(rx_buf[2] == "K", "loaded program did not send 'K'");
        check(gpio_out == 4'hA, "loaded program did not drive the output pins");
        check(!sec_alert, "the alert pin came up during a clean run");

        repeat (20) @(posedge clk);
        if (errors == 0)
            $display("SOC PASS: chip booted, loaded a program over serial and ran it");
        else
            $display("SOC FAIL: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #4000000;
        $display("SOC FAIL: timeout after %0d bytes from the chip", rx_n);
        $finish;
    end

endmodule
