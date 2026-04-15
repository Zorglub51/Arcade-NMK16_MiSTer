// NMK16 — sprite engine + 4 KiB DMA double-buffer
// See docs/architecture.md and hardware reference §C.5-C.6.
//
// STUB — not yet implemented. Phase 4 of docs/roadmap.md.
//
// Source: workram $0F8000-$0F8FFF (256 entries × 16 B).
// DMA trigger: V-PROM bit 0 rising edge (~scanline 242).
// During DMA: assert BUSREQ to 68000 for ~694 µs (≈6940 cycles @10 MHz).
// Render from `spriteram_old2` (one frame delayed).
//
// Per-entry layout (offsets in bytes, 68000 big-endian words):
//   +0  W0 b0       enable
//   +2  W1 b9 b8 b7..4 b3..0   flipY flipX h-1 w-1   (hachamf ignores flips)
//   +6  W3                     tile code (16-bit)
//   +8  W4 b9..0               X position
//   +12 W6 b9..0               Y position
//   +14 W7 b3..0               palette select (16 banks of 16)
//
// Multi-tile: (w+1) x (h+1) 16x16 tiles, codes step by 1 across rows.
// Horizontal +92 px shift; X wrap modulo 512.

`default_nettype none

module sprites (
    input  wire        clk_sys,
    input  wire        rst,

    // Pixel timing
    input  wire        ce_pix,
    input  wire [8:0]  hpos,
    input  wire [8:0]  vpos,
    input  wire        flipscreen,

    // DMA trigger from irq.sv (one-cycle pulse on V-PROM bit 0 rising edge)
    input  wire        sprdma_trigger,

    // Bus mastering: assert during 4 KiB copy
    output reg         busreq,

    // Workram read port (sprite source) — only used during DMA
    output wire [14:0] wram_addr,      // 32KW; sprite source at $4000-$47FF
    input  wire [15:0] wram_din,

    // Sprite GFX ROM (1 MiB; loaded with WORD_SWAP — see docs/roms.md)
    output wire [19:0] spr_gfx_addr,
    input  wire [7:0]  spr_gfx_din,

    // Per-pixel output to mixer
    output wire [3:0]  spr_color,
    output wire [3:0]  spr_pal,
    output wire        spr_opaque,
    output wire [1:0]  spr_pri         // always 2'b10 (GFX_PMASK_2) on hachamf
);

    // TODO: two 4 KiB internal buffers (spriteram_old, spriteram_old2)
    //       implemented as two BRAMs of 2KW each
    // TODO: DMA FSM — copy chain on sprdma_trigger:
    //         spriteram_old2 <= spriteram_old
    //         spriteram_old  <= workram[$F8000..$F8FFF]
    //       hold busreq high during copy
    // TODO: sprite scan engine — walk 256 entries from spriteram_old2,
    //       per entry compute (w+1)x(h+1) tiles, fetch GFX, output pixels
    // TODO: 384*263 = 101952 cycle/frame budget (16 + 128*w*h per sprite)

    always @(posedge clk_sys) begin
        if (rst) busreq <= 1'b0;
    end

    assign wram_addr    = '0;
    assign spr_gfx_addr = '0;
    assign spr_color    = 4'd0;
    assign spr_pal      = 4'd0;
    assign spr_opaque   = 1'b0;
    assign spr_pri      = 2'b10;

endmodule

`default_nettype wire
