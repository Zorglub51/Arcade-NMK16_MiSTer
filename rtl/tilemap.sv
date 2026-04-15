// NMK16 — BG (16x16) + TX (8x8) tile layers
// See docs/architecture.md and hardware reference §C.2-C.4.
//
// Phase 3 implementation: per-pixel combinational lookup of VRAM + GFX ROM.
// Functional but not pipelined. Adequate for Verilator sim; will need
// 2-3 stage pipelining for FPGA timing closure.
//
// BG: 256 cols × 32 rows of 16x16 tiles, 4bpp `col_2x2_group_packed_msb`.
//     Scroll X/Y 16-bit. Tilemap shifted +92 px on screen (videoshift).
//     Tile bank from `bgbank` extends tile_code high 4 bits.
//     VRAM scan: addr = {row[4], col[7:0], row[3:0]} (per nmk16_v.cpp:34-37).
// TX: 32 cols × 32 rows of 8x8 tiles, 4bpp `packed_msb`. No scroll.
//     +92 px H-shift, transparent on pen 15.
//     VRAM scan: COLS-major, addr = col*32 + row.

`default_nettype none

module tilemap (
    input  wire        clk_sys,
    input  wire        rst,

    // Pixel timing from irq.sv (raw, before active-area trim)
    input  wire        ce_pix,
    input  wire [8:0]  hpos,           // 0..383
    input  wire [8:0]  vpos,           // 0..277
    input  wire        flipscreen,     // ignored for Phase 3

    // BG VRAM read port (combinational mux on B side of dual-port)
    output wire [12:0] bgvram_addr,
    input  wire [15:0] bgvram_din,

    // TX VRAM read port
    output wire [9:0]  txvram_addr,
    input  wire [15:0] txvram_din,

    // Scroll + bank registers from CPU side
    input  wire [7:0]  scroll_xh,
    input  wire [7:0]  scroll_xl,
    input  wire [7:0]  scroll_yh,
    input  wire [7:0]  scroll_yl,
    input  wire [7:0]  bgbank,         // BG tile high bits (only [3:0] used in this layout)

    // BG GFX ROM (1 MiB, byte-wide)
    output wire [19:0] bg_gfx_addr,
    input  wire [7:0]  bg_gfx_din,

    // TX GFX ROM (128 KiB, byte-wide)
    output wire [16:0] tx_gfx_addr,
    input  wire [7:0]  tx_gfx_din,

    // Per-pixel output to mixer
    output wire [3:0]  bg_color,
    output wire [3:0]  bg_pal,
    output wire        bg_opaque,      // BG is always opaque (1)

    output wire [3:0]  tx_color,
    output wire [3:0]  tx_pal,
    output wire        tx_opaque       // 0 if tx_color == 4'hF (transparent pen)
);

    localparam int H_SHIFT = 92;
    localparam int V_TOP   = 16;

    // Screen-relative coordinates (offset from active-area origin)
    wire [11:0] screen_x = {3'b0, hpos} - 12'(H_SHIFT);
    wire [11:0] screen_y = {3'b0, vpos} - 12'(V_TOP);

    // -----------------------------------------------------------------
    // BG layer — scrolling 4096×512 tilemap of 16×16 tiles
    // -----------------------------------------------------------------
    wire [15:0] scrollx = {scroll_xh, scroll_xl};
    wire [15:0] scrolly = {scroll_yh, scroll_yl};

    wire [11:0] bg_world_x = (screen_x + scrollx[11:0]) & 12'hFFF;
    wire [8:0]  bg_world_y = (screen_y[8:0] + scrolly[8:0]) & 9'h1FF;

    // VRAM index per nmk16_v.cpp:34-37
    wire [7:0]  bg_tile_col = bg_world_x[11:4];          // 256 cols
    wire [4:0]  bg_tile_row = bg_world_y[8:4];           // 32 rows
    assign bgvram_addr = {bg_tile_row[4], bg_tile_col, bg_tile_row[3:0]};

    wire [11:0] bg_tile_code  = bgvram_din[11:0];
    wire [3:0]  bg_color_bank = bgvram_din[15:12];

    // Effective 16-bit tile index (low 13 bits used = 8192 tiles per 1 MiB ROM)
    wire [15:0] bg_eff_tile  = {4'b0, bg_tile_code} | ({8'b0, bgbank} << 12);
    wire [12:0] bg_eff_tile_lo = bg_eff_tile[12:0];

    // Pixel inside the 16×16 tile
    wire [3:0]  bg_sub_x = bg_world_x[3:0];
    wire [3:0]  bg_sub_y = bg_world_y[3:0];

    // Sub-tile select: TL=0 BL=1 TR=2 BR=3, encoded as {sub_x[3], sub_y[3]}
    // Within each 32 B sub-tile: byte = sub_y[2:0]*4 + sub_x[2:1]
    assign bg_gfx_addr = {bg_eff_tile_lo, bg_sub_x[3], bg_sub_y[3], bg_sub_y[2:0], bg_sub_x[2:1]};

    // Pick nibble: even sub_x = high nibble, odd = low nibble
    wire [3:0] bg_pixel = bg_sub_x[0] ? bg_gfx_din[3:0] : bg_gfx_din[7:4];

    assign bg_color  = bg_pixel;
    assign bg_pal    = bg_color_bank;
    assign bg_opaque = 1'b1;

    // -----------------------------------------------------------------
    // TX layer — fixed 256×256 of 8×8 tiles
    // -----------------------------------------------------------------
    wire [4:0] tx_tile_col = screen_x[7:3];              // 32 cols
    wire [4:0] tx_tile_row = screen_y[7:3];              // 32 rows
    assign txvram_addr = {tx_tile_col, tx_tile_row};     // COLS-major scan

    wire [11:0] tx_tile_code  = txvram_din[11:0];
    wire [3:0]  tx_color_bank = txvram_din[15:12];

    wire [2:0] tx_sub_x = screen_x[2:0];
    wire [2:0] tx_sub_y = screen_y[2:0];

    // 8x8 4bpp packed_msb: byte = tile_code*32 + sub_y*4 + sub_x[2:1]
    assign tx_gfx_addr = {tx_tile_code, tx_sub_y, tx_sub_x[2:1]};

    wire [3:0] tx_pixel = tx_sub_x[0] ? tx_gfx_din[3:0] : tx_gfx_din[7:4];

    assign tx_color  = tx_pixel;
    assign tx_pal    = tx_color_bank;
    assign tx_opaque = (tx_pixel != 4'hF);

endmodule

`default_nettype wire
