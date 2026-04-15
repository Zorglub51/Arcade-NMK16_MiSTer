//============================================================================
// NMK16 / Hacha Mecha Fighter core for MiSTer — emu top-level
//
// Phase 7 v1 SMOKE TEST build:
//   - Program ROM: loaded into BRAM from MRA via ioctl_index=0
//   - Workram, VRAMs, palette: all BRAM (inside nmk16_core)
//   - GFX ROMs: NOT LOADED; BG/TX/sprite data pins tied to 0 in v1
//   - Audio: silent (Phase 5 adds jt03 + jt6295)
//
// Expected v1 behaviour on real HW:
//   - Core boots, CPU runs hachamfb program
//   - HPS OSD works (Reset, joystick config)
//   - Display shows a partial image (tile shapes invisible since GFX=0, but
//     palette colours + sprite silhouettes should appear)
//   - Inputs reach the game
//
// v2 will add a simple SDRAM controller + GFX ROM loading for real picture.
//============================================================================

module emu
(
    input         CLK_50M,
    input         RESET,
    inout  [48:0] HPS_BUS,

    output        CLK_VIDEO,
    output        CE_PIXEL,

    output [12:0] VIDEO_ARX,
    output [12:0] VIDEO_ARY,

    output  [7:0] VGA_R,
    output  [7:0] VGA_G,
    output  [7:0] VGA_B,
    output        VGA_HS,
    output        VGA_VS,
    output        VGA_DE,
    output        VGA_F1,
    output [1:0]  VGA_SL,
    output        VGA_SCALER,
    output        VGA_DISABLE,

    input  [11:0] HDMI_WIDTH,
    input  [11:0] HDMI_HEIGHT,
    output        HDMI_FREEZE,
    output        HDMI_BLACKOUT,
    output        HDMI_BOB_DEINT,

    output        LED_USER,
    output  [1:0] LED_POWER,
    output  [1:0] LED_DISK,
    output  [1:0] BUTTONS,

    input         CLK_AUDIO,
    output [15:0] AUDIO_L,
    output [15:0] AUDIO_R,
    output        AUDIO_S,
    output  [1:0] AUDIO_MIX,

    inout   [3:0] ADC_BUS,

    output        SD_SCK, output SD_MOSI,
    input         SD_MISO,
    output        SD_CS,
    input         SD_CD,

    output        DDRAM_CLK,
    input         DDRAM_BUSY,
    output  [7:0] DDRAM_BURSTCNT,
    output [28:0] DDRAM_ADDR,
    input  [63:0] DDRAM_DOUT,
    input         DDRAM_DOUT_READY,
    output        DDRAM_RD,
    output [63:0] DDRAM_DIN,
    output  [7:0] DDRAM_BE,
    output        DDRAM_WE,

    output        SDRAM_CLK, SDRAM_CKE,
    output [12:0] SDRAM_A,
    output  [1:0] SDRAM_BA,
    inout  [15:0] SDRAM_DQ,
    output        SDRAM_DQML, SDRAM_DQMH,
    output        SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE,

    input         UART_CTS,
    output        UART_RTS,
    input         UART_RXD,
    output        UART_TXD,
    output        UART_DTR,
    input         UART_DSR,

    input   [6:0] USER_IN,
    output  [6:0] USER_OUT,

    input         OSD_STATUS
);

///////// Ports not used in this smoke-test build /////////
assign ADC_BUS     = 'Z;
assign USER_OUT    = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS}       = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH,
        SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;
assign VGA_SL       = 0;
assign VGA_F1       = 0;
assign VGA_SCALER   = 0;
assign VGA_DISABLE  = 0;
assign HDMI_FREEZE  = 0;
assign HDMI_BLACKOUT= 0;
assign HDMI_BOB_DEINT=0;
assign LED_DISK     = 0;
assign LED_POWER    = 0;
assign BUTTONS      = 0;
assign AUDIO_MIX    = 0;

assign VIDEO_ARX = 12'd4;
assign VIDEO_ARY = 12'd3;

////////////////////////// OSD config string //////////////////////////
`include "build_id.v"
localparam CONF_STR = {
    "NMK16;;",
    "-;",
    "F0,BIN,Load ROM;",
    "-;",
    "O[1],Lives,3,4;",
    "O[2],Language,English,Japanese;",
    "-;",
    "T[0],Reset;",
    "R[0],Reset and close OSD;",
    "V,v",`BUILD_DATE
};

////////////////////////// Clocks //////////////////////////
wire clk_sys;       // master clock, target 96 MHz from PLL
wire pll_locked;

pll pll (
    .refclk  (CLK_50M),
    .rst     (0),
    .outclk_0(clk_sys),
    .locked  (pll_locked)
);

////////////////////////// HPS interface //////////////////////////
wire        forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;

wire [15:0] joy0, joy1;

wire        ioctl_download;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire [7:0]  ioctl_dout;
wire [7:0]  ioctl_index;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
    .clk_sys(clk_sys),
    .HPS_BUS(HPS_BUS),
    .EXT_BUS(),
    .gamma_bus(),

    .forced_scandoubler(forced_scandoubler),
    .buttons(buttons),
    .status(status),

    .joystick_0(joy0),
    .joystick_1(joy1),

    .ioctl_download(ioctl_download),
    .ioctl_wr(ioctl_wr),
    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),
    .ioctl_index(ioctl_index)
);

wire reset = RESET | status[0] | buttons[1] | ioctl_download | ~pll_locked;

////////////////////////// Program ROM — 256 KiB BRAM //////////////////////////
// ioctl_index == 0 → program ROM bytes stream in as {addr, byte}.
// Pack into 16-bit big-endian words: even addrs = high byte, odd = low byte.

reg  [15:0] prog_rom [0:131071];
wire [16:0] prog_rom_addr;
wire [15:0] prog_rom_data;

always @(posedge clk_sys) begin
    if (ioctl_download && ioctl_wr && ioctl_index == 8'd0) begin
        // Big-endian word packing
        if (ioctl_addr[0])
            prog_rom[ioctl_addr[17:1]][ 7:0] <= ioctl_dout;
        else
            prog_rom[ioctl_addr[17:1]][15:8] <= ioctl_dout;
    end
end

reg [15:0] prog_rom_reg;
always @(posedge clk_sys) prog_rom_reg <= prog_rom[prog_rom_addr];
assign prog_rom_data = prog_rom_reg;

////////////////////////// GFX ROMs — v1 placeholder //////////////////////////
// v1: tied to 0. Core still runs; display will have palette colours but no
// tile patterns. v2 will route these to SDRAM.
wire [19:0] bg_gfx_addr;
wire [16:0] tx_gfx_addr;
wire [19:0] spr_gfx_addr;

wire [7:0] bg_gfx_data  = 8'h00;
wire [7:0] tx_gfx_data  = 8'h00;
wire [7:0] spr_gfx_data = 8'h00;

////////////////////////// Joystick → NMK16 inputs //////////////////////////
// joy0/joy1 standard MiSTer mapping:
//   [0]=Right [1]=Left [2]=Down [3]=Up [4]=Btn1 [5]=Btn2 [6]=Btn3
//   [8]=Start [9]=Coin [10]=Service
// Convert to active-low NMK16 IN0 (coin/svc/start) and IN1 (P1+P2).
wire [7:0]  in0_keys =
    8'hFF &
    ~(joy0[9]  ? 8'h01 : 0) &     // COIN1
    ~(joy1[9]  ? 8'h02 : 0) &     // COIN2
    ~(joy0[10] ? 8'h04 : 0) &     // SERVICE1
    ~(joy0[8]  ? 8'h08 : 0) &     // START1
    ~(joy1[8]  ? 8'h10 : 0);      // START2

wire [15:0] in1_keys =
    16'hFFFF &
    ~(joy0[0] ? 16'h0001 : 0) &   // P1 Right
    ~(joy0[1] ? 16'h0002 : 0) &   // P1 Left
    ~(joy0[2] ? 16'h0004 : 0) &   // P1 Down
    ~(joy0[3] ? 16'h0008 : 0) &   // P1 Up
    ~(joy0[4] ? 16'h0010 : 0) &   // P1 B1
    ~(joy0[5] ? 16'h0020 : 0) &   // P1 B2
    ~(joy1[0] ? 16'h0100 : 0) &   // P2 Right
    ~(joy1[1] ? 16'h0200 : 0) &
    ~(joy1[2] ? 16'h0400 : 0) &
    ~(joy1[3] ? 16'h0800 : 0) &
    ~(joy1[4] ? 16'h1000 : 0) &
    ~(joy1[5] ? 16'h2000 : 0);

wire [7:0] dsw1 = {~status[2], status[1], 6'h3F}; // language + lives from OSD
wire [7:0] dsw2 = 8'hFF;

////////////////////////// Core instance //////////////////////////
wire        core_ce_pix;
wire [8:0]  core_hpos, core_vpos;
wire        core_hs, core_vs, core_hb, core_vb, core_de;
wire [7:0]  core_r, core_g, core_b;
wire signed [15:0] core_audio_l, core_audio_r;

nmk16_core u_core (
    .clk            (clk_sys),
    .rst            (reset),

    .in0_keys       (in0_keys),
    .in1_keys       (in1_keys),
    .dsw1           (dsw1),
    .dsw2           (dsw2),

    .prog_rom_addr  (prog_rom_addr),
    .prog_rom_data  (prog_rom_data),
    .bg_gfx_addr    (bg_gfx_addr),
    .bg_gfx_data    (bg_gfx_data),
    .tx_gfx_addr    (tx_gfx_addr),
    .tx_gfx_data    (tx_gfx_data),
    .spr_gfx_addr   (spr_gfx_addr),
    .spr_gfx_data   (spr_gfx_data),

    .ce_pix         (core_ce_pix),
    .hpos           (core_hpos),
    .vpos           (core_vpos),
    .hsync          (core_hs),
    .vsync          (core_vs),
    .hblank         (core_hb),
    .vblank         (core_vb),
    .vga_r          (core_r),
    .vga_g          (core_g),
    .vga_b          (core_b),
    .vga_de         (core_de),

    .audio_l        (core_audio_l),
    .audio_r        (core_audio_r)
);

////////////////////////// Video out //////////////////////////
assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = core_ce_pix;
assign VGA_R     = core_r;
assign VGA_G     = core_g;
assign VGA_B     = core_b;
assign VGA_HS    = core_hs;   // active-low
assign VGA_VS    = core_vs;
assign VGA_DE    = core_de;

////////////////////////// Audio //////////////////////////
assign AUDIO_L = core_audio_l;
assign AUDIO_R = core_audio_r;
assign AUDIO_S = 1'b1;        // signed

////////////////////////// Activity LED //////////////////////////
reg [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
assign LED_USER = act_cnt[26] ? act_cnt[25:18] > act_cnt[7:0]
                              : act_cnt[25:18] <= act_cnt[7:0];

endmodule
