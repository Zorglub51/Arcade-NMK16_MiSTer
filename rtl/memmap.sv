// NMK16 — 68000 address decoder + bus arbiter
// See docs/memmap.md and hardware reference §B.
//
// STUB — not yet implemented. Phases 1-2 of docs/roadmap.md.

`default_nettype none

module memmap (
    input  wire        clk_sys,
    input  wire        rst,

    // 68000 bus (fx68k convention, big-endian D15..D0)
    input  wire [23:1] cpu_addr,       // word-addressable
    input  wire [15:0] cpu_dout,
    output reg  [15:0] cpu_din,
    input  wire        cpu_as_n,       // address strobe
    input  wire        cpu_uds_n,      // upper data strobe (D15..D8)
    input  wire        cpu_lds_n,      // lower data strobe (D7..D0)
    input  wire        cpu_rw,         // 1=read 0=write
    output reg         cpu_dtack_n,
    output wire        cpu_br_n,       // bus request to 68000 (sprite DMA / NMK-113)
    input  wire        cpu_bg_n,       // bus grant from 68000
    output wire        cpu_bgack_n,

    // External DMA requests
    input  wire        sprdma_busreq,  // from sprites.sv during 4 KiB DMA
    input  wire        prot_busreq,    // from audio.sv (NMK-113 HALT) — phase 6

    // VRAM ports (dual-port, side B serves video)
    // BG VRAM 8KW
    output wire [12:0] bgvram_addr,
    output wire [15:0] bgvram_dout,
    input  wire [15:0] bgvram_din,
    output wire        bgvram_we,
    output wire        bgvram_ub,
    output wire        bgvram_lb,

    // TX VRAM 1KW
    output wire [9:0]  txvram_addr,
    output wire [15:0] txvram_dout,
    input  wire [15:0] txvram_din,
    output wire        txvram_we,
    output wire        txvram_ub,
    output wire        txvram_lb,

    // Palette RAM 1KW
    output wire [9:0]  pal_addr,
    output wire [15:0] pal_dout,
    input  wire [15:0] pal_din,
    output wire        pal_we,
    output wire        pal_ub,
    output wire        pal_lb,

    // Workram 32KW (includes sprite source at $0F8000-$0F8FFF = words $4000-$47FF)
    output wire [14:0] wram_addr,
    output wire [15:0] wram_dout,
    input  wire [15:0] wram_din,
    output wire        wram_we,
    output wire        wram_ub,
    output wire        wram_lb,

    // Program ROM 128KW
    output wire [16:0] rom_addr,
    input  wire [15:0] rom_din,

    // Control register fan-out
    output reg         flipscreen,     // $080015 b0
    output reg  [7:0]  bgbank,         // $080019 BG tile high bits
    output reg  [7:0]  scroll_xh,      // $08C001
    output reg  [7:0]  scroll_xl,      // $08C003
    output reg  [7:0]  scroll_yh,      // $08C005
    output reg  [7:0]  scroll_yl,      // $08C007

    // NMK004 latches + watchdog (from audio.sv)
    output reg  [7:0]  nmk004_to_snd,
    output reg         nmk004_to_snd_we,
    input  wire [7:0]  nmk004_to_main,
    output reg         nmk004_nmi,     // $080016 b0

    // Inputs / DIPs
    input  wire [7:0]  in0,
    input  wire [15:0] in1,
    input  wire [7:0]  dsw1,
    input  wire [7:0]  dsw2
);

    // TODO: address decode per docs/memmap.md
    // TODO: DTACK gen
    // TODO: BG, BR/BGACK arbitration when sprdma_busreq or prot_busreq

    assign cpu_br_n     = ~(sprdma_busreq | prot_busreq);
    assign cpu_bgack_n  = 1'b1;
    assign bgvram_addr  = '0; assign bgvram_dout = '0;
    assign bgvram_we    = 1'b0; assign bgvram_ub = 1'b0; assign bgvram_lb = 1'b0;
    assign txvram_addr  = '0; assign txvram_dout = '0;
    assign txvram_we    = 1'b0; assign txvram_ub = 1'b0; assign txvram_lb = 1'b0;
    assign pal_addr     = '0; assign pal_dout = '0;
    assign pal_we       = 1'b0; assign pal_ub = 1'b0; assign pal_lb = 1'b0;
    assign wram_addr    = '0; assign wram_dout = '0;
    assign wram_we      = 1'b0; assign wram_ub = 1'b0; assign wram_lb = 1'b0;
    assign rom_addr     = '0;

    always @(*) begin
        cpu_din          = 16'hFFFF;
        cpu_dtack_n      = 1'b1;
        nmk004_to_snd    = 8'h00;
        nmk004_to_snd_we = 1'b0;
    end

    always @(posedge clk_sys) begin
        if (rst) begin
            flipscreen <= 1'b0;
            bgbank     <= 8'h00;
            scroll_xh  <= 8'h00; scroll_xl <= 8'h00;
            scroll_yh  <= 8'h00; scroll_yl <= 8'h00;
            nmk004_nmi <= 1'b0;
        end
    end

endmodule

`default_nettype wire
