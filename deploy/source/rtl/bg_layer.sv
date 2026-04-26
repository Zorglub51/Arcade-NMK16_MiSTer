// NMK16 BG layer — pipelined reads through SDRAM-style req/valid GFX port.
//
// Drop-in replacement for the BG portion of rtl/tilemap.sv. Same
// scroll/bgbank semantics, same VRAM/GFX address formats, but the GFX
// fetch is now a request/valid handshake (matches one channel of
// rtl/sdram.sv) instead of same-cycle byte read.
//
// Architecture (v1, per-pixel fetch):
//   - Each ce_pix tick kicks off a fresh fetch chain:
//       F_VRAM   : drive bgvram_addr, capture bgvram_din next cycle
//       F_GFX_REQ: issue gfx_req, capture spr_gfx_addr[0] & sub_x_lsb
//       F_GFX_WAIT: wait for gfx_valid → latch byte
//   - The chain finishes well within one ce_pix period (1 + 1 + ~6 + 1 = 9
//     master cycles vs 16 cycles per ce_pix at PIX_DIV=16). The latched
//     byte + palette + sub_x_lsb feed bg_color/bg_pal combinationally —
//     stable across the next ce_pix period for the mixer to sample.
//   - 1-pixel-pair lookahead: the layer fetches for hpos+1 so the latched
//     result is valid for the *next* ce_pix's hpos. That keeps the layer's
//     output frame-aligned with the mixer despite the ~9-cycle pipeline.
//
// v1 is per-byte (1 SDRAM read per pixel-pair). v2 will widen to per-word
// reads (1 SDRAM read per 4 pixels) once we're confident on the bandwidth
// model.

`default_nettype none

module bg_layer (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce_pix,

    input  wire [8:0]  hpos,           // 0..383
    input  wire [8:0]  vpos,           // 0..277

    input  wire [7:0]  scroll_xh,
    input  wire [7:0]  scroll_xl,
    input  wire [7:0]  scroll_yh,
    input  wire [7:0]  scroll_yl,
    input  wire [7:0]  bgbank,

    // BG VRAM read port (1-cycle synchronous read; data arrives on the
    // clock after `bgvram_addr` is driven). In sim it's combinational
    // and lands the same cycle, which is also fine — pipeline still works.
    output reg  [12:0] bgvram_addr,
    input  wire [15:0] bgvram_din,

    // GFX ROM read port (req/valid; data is 16-bit word with byte selected
    // by addr[0]).
    output reg         gfx_req,
    input  wire        gfx_ack,
    output reg  [23:0] gfx_addr,
    input  wire [15:0] gfx_data,
    input  wire        gfx_valid,

    // Per-pixel output (combinational from latched fetch results).
    output wire [3:0]  bg_color,
    output wire [3:0]  bg_pal,
    output wire        bg_opaque
);

    localparam int H_SHIFT = 92;
    localparam int V_TOP   = 16;

    // -----------------------------------------------------------------
    // Lookahead: the layer fetches for the *next* pixel so the result is
    // ready when the mixer samples bg_color at the upcoming ce_pix tick.
    // -----------------------------------------------------------------
    wire [8:0] hpos_lookahead = hpos + 9'd1;

    // -----------------------------------------------------------------
    // Combinational world coords for the lookahead pixel.
    // -----------------------------------------------------------------
    wire [11:0] f_screen_x = {3'b0, hpos_lookahead} - 12'(H_SHIFT);
    wire [11:0] f_screen_y = {3'b0, vpos}           - 12'(V_TOP);
    wire [15:0] scrollx    = {scroll_xh, scroll_xl};
    wire [15:0] scrolly    = {scroll_yh, scroll_yl};

    wire [11:0] f_world_x = (f_screen_x + scrollx[11:0]) & 12'hFFF;
    wire [8:0]  f_world_y = (f_screen_y[8:0] + scrolly[8:0]) & 9'h1FF;

    wire [7:0]  f_tile_col = f_world_x[11:4];
    wire [4:0]  f_tile_row = f_world_y[8:4];
    wire [12:0] f_bgvram_addr = {f_tile_row[4], f_tile_col, f_tile_row[3:0]};

    wire [3:0]  f_sub_x = f_world_x[3:0];
    wire [3:0]  f_sub_y = f_world_y[3:0];

    // -----------------------------------------------------------------
    // Fetch state machine — runs one full chain per ce_pix tick.
    // -----------------------------------------------------------------
    localparam [2:0]
        F_IDLE     = 3'd0,
        F_VRAM     = 3'd1,
        F_VRAM_WAIT= 3'd2,
        F_GFX_REQ  = 3'd3,
        F_GFX_WAIT = 3'd4;

    reg [2:0]  fstate;
    reg [11:0] f_tile_code_lat;
    reg [3:0]  f_pal_lat;        // bgvram_din[15:12]
    reg [3:0]  f_sub_x_lat;      // captured at F_VRAM
    reg [3:0]  f_sub_y_lat;
    reg [7:0]  byte_lat;         // result byte from gfx_data
    reg [3:0]  pal_out;          // palette latched at fetch completion
    reg [3:0]  sub_x_lsb_lat;    // sub_x for nibble select at output

    // GFX byte address derived from latched tile_code + sub coords
    wire [15:0] f_eff_tile    = {4'b0, f_tile_code_lat} | ({8'b0, bgbank} << 12);
    wire [12:0] f_eff_tile_lo = f_eff_tile[12:0];
    wire [19:0] f_gfx_byte_addr = {f_eff_tile_lo, f_sub_x_lat[3], f_sub_y_lat[3],
                                   f_sub_y_lat[2:0], f_sub_x_lat[2:1]};

    always @(posedge clk) begin
        if (rst) begin
            fstate         <= F_IDLE;
            bgvram_addr    <= 13'd0;
            gfx_req        <= 1'b0;
            gfx_addr       <= 24'd0;
            f_tile_code_lat<= 12'd0;
            f_pal_lat      <= 4'd0;
            f_sub_x_lat    <= 4'd0;
            f_sub_y_lat    <= 4'd0;
            byte_lat       <= 8'd0;
            pal_out        <= 4'd0;
            sub_x_lsb_lat  <= 4'd0;
        end else begin
            // gfx_req drops when ack pulses (1-cycle handshake).
            if (gfx_ack) gfx_req <= 1'b0;

            case (fstate)
                F_IDLE: if (ce_pix) begin
                    // Start a new fetch chain for the lookahead pixel.
                    bgvram_addr <= f_bgvram_addr;
                    f_sub_x_lat <= f_sub_x;
                    f_sub_y_lat <= f_sub_y;
                    fstate      <= F_VRAM;
                end

                F_VRAM: begin
                    // bgvram_din arrives this cycle (1-cycle BRAM). Capture.
                    f_tile_code_lat <= bgvram_din[11:0];
                    f_pal_lat       <= bgvram_din[15:12];
                    fstate          <= F_GFX_REQ;
                end

                F_GFX_REQ: begin
                    // Request the GFX byte.
                    gfx_req  <= 1'b1;
                    gfx_addr <= {4'd0, f_gfx_byte_addr};
                    fstate   <= F_GFX_WAIT;
                end

                F_GFX_WAIT: begin
                    if (gfx_valid) begin
                        // 16-bit word; pick byte by addr[0].
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
    // sub_x_lsb_lat[0] selects which nibble of the byte: even = high, odd = low.
    assign bg_color  = sub_x_lsb_lat[0] ? byte_lat[3:0] : byte_lat[7:4];
    assign bg_pal    = pal_out;
    assign bg_opaque = 1'b1;

endmodule

`default_nettype wire
