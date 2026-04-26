// NMK16 TX layer — pipelined reads through SDRAM-style req/valid GFX port.
//
// Drop-in replacement for the TX portion of rtl/tilemap.sv. Same VRAM/GFX
// address formats as the original, but the GFX fetch is a request/valid
// handshake (matches one channel of rtl/sdram.sv).
//
// TX is the simpler of the two layers:
//   - Fixed 32×32 grid of 8×8 4bpp tiles (256×256 logical)
//   - No scroll, no tile bank, transparent pen 15
//
// Same per-pixel fetch architecture as bg_layer.sv. See that module's
// header for the full pipeline write-up.

`default_nettype none

module tx_layer (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce_pix,

    input  wire [8:0]  hpos,           // 0..383
    input  wire [8:0]  vpos,           // 0..277

    // TX VRAM read port (1-cycle synchronous).
    output reg  [9:0]  txvram_addr,
    input  wire [15:0] txvram_din,

    // GFX ROM read port (req/valid; 16-bit word, byte by addr[0]).
    output reg         gfx_req,
    input  wire        gfx_ack,
    output reg  [23:0] gfx_addr,
    input  wire [15:0] gfx_data,
    input  wire        gfx_valid,

    // Per-pixel output.
    output wire [3:0]  tx_color,
    output wire [3:0]  tx_pal,
    output wire        tx_opaque
);

    localparam int H_SHIFT = 92;
    localparam int V_TOP   = 16;

    // 1-pixel lookahead so the latched fetch result is valid for the
    // *next* ce_pix's hpos. See bg_layer.sv for rationale.
    wire [8:0]  hpos_lookahead = hpos + 9'd1;
    wire [11:0] f_screen_x = {3'b0, hpos_lookahead} - 12'(H_SHIFT);
    wire [11:0] f_screen_y = {3'b0, vpos}           - 12'(V_TOP);

    // 32-col × 32-row grid of 8×8 tiles, COLS-major scan.
    wire [4:0]  f_tile_col = f_screen_x[7:3];
    wire [4:0]  f_tile_row = f_screen_y[7:3];
    wire [9:0]  f_txvram_addr = {f_tile_col, f_tile_row};
    wire [2:0]  f_sub_x = f_screen_x[2:0];
    wire [2:0]  f_sub_y = f_screen_y[2:0];

    // -----------------------------------------------------------------
    // Fetch state machine — one chain per ce_pix tick.
    // -----------------------------------------------------------------
    localparam [2:0]
        F_IDLE     = 3'd0,
        F_VRAM     = 3'd1,
        F_GFX_REQ  = 3'd2,
        F_GFX_WAIT = 3'd3;

    reg [2:0]  fstate;
    reg [11:0] f_tile_code_lat;
    reg [3:0]  f_pal_lat;          // txvram_din[15:12]
    reg [2:0]  f_sub_x_lat;
    reg [2:0]  f_sub_y_lat;
    reg [7:0]  byte_lat;
    reg [3:0]  pal_out;
    reg [2:0]  sub_x_lsb_lat;

    // 8×8 4bpp packed_msb: gfx byte addr = {tile_code, sub_y, sub_x[2:1]}
    wire [16:0] f_gfx_byte_addr = {f_tile_code_lat, f_sub_y_lat, f_sub_x_lat[2:1]};

    always @(posedge clk) begin
        if (rst) begin
            fstate          <= F_IDLE;
            txvram_addr     <= 10'd0;
            gfx_req         <= 1'b0;
            gfx_addr        <= 24'd0;
            f_tile_code_lat <= 12'd0;
            f_pal_lat       <= 4'd0;
            f_sub_x_lat     <= 3'd0;
            f_sub_y_lat     <= 3'd0;
            byte_lat        <= 8'd0;
            pal_out         <= 4'd0;
            sub_x_lsb_lat   <= 3'd0;
        end else begin
            if (gfx_ack) gfx_req <= 1'b0;

            case (fstate)
                F_IDLE: if (ce_pix) begin
                    txvram_addr <= f_txvram_addr;
                    f_sub_x_lat <= f_sub_x;
                    f_sub_y_lat <= f_sub_y;
                    fstate      <= F_VRAM;
                end

                F_VRAM: begin
                    f_tile_code_lat <= txvram_din[11:0];
                    f_pal_lat       <= txvram_din[15:12];
                    fstate          <= F_GFX_REQ;
                end

                F_GFX_REQ: begin
                    gfx_req  <= 1'b1;
                    gfx_addr <= {7'd0, f_gfx_byte_addr};
                    fstate   <= F_GFX_WAIT;
                end

                F_GFX_WAIT: begin
                    if (gfx_valid) begin
                        byte_lat      <= gfx_addr[0] ? gfx_data[7:0]
                                                     : gfx_data[15:8];
                        pal_out       <= f_pal_lat;
                        sub_x_lsb_lat <= f_sub_x_lat;
                        fstate        <= F_IDLE;
                    end
                end

                default: fstate <= F_IDLE;
            endcase
        end
    end

    // Per-pixel output — combinational from latched fetch result.
    wire [3:0] pixel = sub_x_lsb_lat[0] ? byte_lat[3:0] : byte_lat[7:4];

    assign tx_color  = pixel;
    assign tx_pal    = pal_out;
    assign tx_opaque = (pixel != 4'hF);

endmodule

`default_nettype wire
