// Routes the MiSTer HPS_IO ioctl stream into SDRAM writes, packing byte
// pairs into 16-bit words.
//
// ioctl_index layout (matches mra/hachamfb.mra):
//   1 = TX GFX  (5.95, 128 KiB)        → SDRAM[0x100000..0x11FFFF]
//   2 = BG GFX  (91076-4.101, 1 MiB)   → SDRAM[0x200000..0x2FFFFF]
//   3 = Sprite  (91076-8.57, 1 MiB)    → SDRAM[0x400000..0x4FFFFF]
//   others ignored here (prog ROM & OKI loaded elsewhere)

`default_nettype none

module gfx_loader (
    input  wire        clk,
    input  wire        rst,

    // From hps_io
    input  wire        ioctl_download,
    input  wire        ioctl_wr,
    input  wire [24:0] ioctl_addr,       // byte index within the stream
    input  wire [7:0]  ioctl_dout,
    input  wire [7:0]  ioctl_index,

    // To SDRAM controller
    output reg         sdram_wr_req,
    input  wire        sdram_wr_ack,
    output reg  [23:0] sdram_wr_addr,    // byte-addressed
    output reg  [15:0] sdram_wr_data,
    output reg  [1:0]  sdram_wr_be,      // {UB,LB} active-low; 0 = byte written

    // 1 while a ROM is actively being streamed to SDRAM
    output reg         busy
);

    // Base SDRAM addresses per index (byte-addressed).
    // Laid out on fresh bank boundaries so rows rarely cross.
    function automatic [23:0] base_addr(input [7:0] idx);
        case (idx)
            8'd1:   base_addr = 24'h100000;   // TX GFX
            8'd2:   base_addr = 24'h200000;   // BG GFX
            8'd3:   base_addr = 24'h400000;   // sprite GFX
            default: base_addr = 24'h000000;
        endcase
    endfunction

    wire is_gfx_idx = (ioctl_index == 8'd1)
                   || (ioctl_index == 8'd2)
                   || (ioctl_index == 8'd3);

    reg [7:0]  byte_hold;    // holds the low byte until the next (high) byte arrives
    reg        hold_valid;
    reg [24:0] last_ioctl_addr;

    always @(posedge clk) begin
        if (rst) begin
            sdram_wr_req    <= 1'b0;
            sdram_wr_addr   <= 24'h0;
            sdram_wr_data   <= 16'h0;
            sdram_wr_be     <= 2'b00;
            byte_hold       <= 8'h0;
            hold_valid      <= 1'b0;
            busy            <= 1'b0;
            last_ioctl_addr <= '0;
        end else begin
            // SDRAM acked our previous request → clear it
            if (sdram_wr_req && sdram_wr_ack) begin
                sdram_wr_req <= 1'b0;
            end

            busy <= ioctl_download && is_gfx_idx;

            if (ioctl_download && ioctl_wr && is_gfx_idx) begin
                last_ioctl_addr <= ioctl_addr;
                if (!ioctl_addr[0]) begin
                    // Even byte — stash, write on next
                    byte_hold  <= ioctl_dout;
                    hold_valid <= 1'b1;
                end else begin
                    // Odd byte — pack pair, issue SDRAM write at even-addr
                    sdram_wr_data <= hold_valid ? {byte_hold, ioctl_dout}
                                                : {8'h00,    ioctl_dout};
                    sdram_wr_addr <= base_addr(ioctl_index)
                                   | {3'b000, ioctl_addr[19:1], 1'b0};
                    sdram_wr_be   <= 2'b00;
                    sdram_wr_req  <= 1'b1;
                    hold_valid    <= 1'b0;
                end
            end
        end
    end

endmodule

`default_nettype wire
