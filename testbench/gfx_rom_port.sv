// Sim-only GFX ROM read port. Same protocol as one channel of rtl/sdram.sv:
//
//   layer drives  : req, addr
//   port responds : ack pulse (1 cycle when accepted), data + valid pulse later
//
// Backed by a combinational view of the testbench's $fread'd byte array:
// the testbench drives `rom_word_in` from its byte array indexed by
// `rom_addr_out`. The port latches the address at request time and holds it
// across the latency window so the testbench can sample the right word.
//
// LATENCY parameter sets request → valid delay in master clock cycles.
// Default 6 matches typical sdram.sv read latency (ACT + tRCD + READ + CL=2).
//
// Pixel parity check:
//   Same hpos/vpos → same addr → same data, regardless of LATENCY value.
//   Latency only changes the *time* the data appears, never the data itself.
//   That is the contract that lets us use this stub as a faithful SDRAM proxy.

`default_nettype none

module gfx_rom_port #(
    parameter int LATENCY = 6
) (
    input  wire        clk,
    input  wire        rst,

    // Layer-side request/valid protocol
    input  wire        req,
    output reg         ack,
    input  wire [23:0] addr,
    output reg  [15:0] data,
    output reg         valid,

    // Backing-store interface (combinational, driven by testbench)
    output reg  [23:0] rom_addr_out,    // latched address — read array at this addr
    input  wire [15:0] rom_word_in      // {byte at addr&~1, byte at addr|1}
);

    reg [3:0] latency_cnt;
    reg       in_flight;

    always @(posedge clk) begin
        ack   <= 1'b0;
        valid <= 1'b0;
        if (rst) begin
            in_flight   <= 1'b0;
            latency_cnt <= 4'd0;
        end else begin
            if (req && !in_flight) begin
                ack          <= 1'b1;
                in_flight    <= 1'b1;
                latency_cnt  <= 4'd0;
                rom_addr_out <= addr;
            end else if (in_flight) begin
                if (latency_cnt == LATENCY[3:0]-4'd1) begin
                    data      <= rom_word_in;
                    valid     <= 1'b1;
                    in_flight <= 1'b0;
                end else begin
                    latency_cnt <= latency_cnt + 4'd1;
                end
            end
        end
    end

endmodule

`default_nettype wire
