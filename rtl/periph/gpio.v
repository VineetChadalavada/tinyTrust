// TinyTrust -- general purpose I/O (S1-A)
//
// REGISTERS (word offsets within the GPIO block)
//   0x0  OUT   value driven on the output pins
//   0x4  IN    value read from the input pins
//
// The inputs are synchronised through two flip-flops. They come from pins
// and are asynchronous to this clock, so reading them directly would
// eventually latch a metastable value. This costs two flip-flops per pin and
// removes a class of failure that is close to impossible to reproduce.

module gpio #(
    parameter W = 4
) (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         sel,
    input  wire [3:2]   addr,
    input  wire         we,
    input  wire [31:0]  wdata,
    output reg  [31:0]  rdata,

    output reg  [W-1:0] gpio_out,
    input  wire [W-1:0] gpio_in
);

    localparam [1:0] R_OUT = 2'd0,
                     R_IN  = 2'd1;

    reg [W-1:0] in_meta, in_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_meta <= {W{1'b0}};
            in_sync <= {W{1'b0}};
        end else begin
            in_meta <= gpio_in;
            in_sync <= in_meta;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            gpio_out <= {W{1'b0}};
        else if (sel && we && (addr == R_OUT[1:0]))
            gpio_out <= wdata[W-1:0];
    end

    always @* begin
        case (addr)
            R_OUT[1:0]: rdata = {{(32-W){1'b0}}, gpio_out};
            R_IN [1:0]: rdata = {{(32-W){1'b0}}, in_sync};
            default:    rdata = 32'd0;
        endcase
    end

endmodule
