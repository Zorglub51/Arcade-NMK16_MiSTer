// NMK16 / Hacha Mecha Fighter — top-level
// See docs/architecture.md for block diagram.
//
// STUB — not yet implemented. Phase 0 of docs/roadmap.md.

`default_nettype none

module top (
    input  wire        clk_sys,        // master pixel-PLL clock (e.g. 96 MHz)
    input  wire        rst,            // synchronous active-high

    // Player inputs (active-low at the chip; convert from MiSTer joy_* upstream)
    input  wire [15:0] in1,            // P1+P2 directions/buttons (see docs/memmap.md IN1)
    input  wire [7:0]  in0,            // coins, service, start (see docs/memmap.md IN0)
    input  wire [7:0]  dsw1,
    input  wire [7:0]  dsw2,

    // ROM load (HPS_IO side, from MiSTer sys/)
    input  wire        rom_we,
    input  wire [24:0] rom_addr,
    input  wire [7:0]  rom_data,
    input  wire [3:0]  rom_index,      // 0=maincpu 1=fgtile 2=bgtile 3=sprites 4=oki1 5=oki2 6=nmk004

    // Video out (RGB to scaler)
    output wire [4:0]  vid_r,
    output wire [4:0]  vid_g,
    output wire [4:0]  vid_b,
    output wire        vid_hsync,
    output wire        vid_vsync,
    output wire        vid_hblank,
    output wire        vid_vblank,
    output wire        vid_ce_pix,     // 6 MHz pixel clock-enable

    // Audio out
    output wire signed [15:0] aud_l,
    output wire signed [15:0] aud_r
);

    // TODO Phase 0: drive a static test pattern on vid_*, silence on aud_*.
    // TODO Phase 1: instantiate fx68k + memmap.
    // TODO Phase 2: instantiate irq.sv, wire IPL[2:0].
    // TODO Phase 3: instantiate tilemap.sv, wire palette+mixer.
    // TODO Phase 4: instantiate sprites.sv, wire DMA + BUSREQ.
    // TODO Phase 5: instantiate audio.sv.

    assign vid_r      = 5'd0;
    assign vid_g      = 5'd0;
    assign vid_b      = 5'd0;
    assign vid_hsync  = 1'b0;
    assign vid_vsync  = 1'b0;
    assign vid_hblank = 1'b1;
    assign vid_vblank = 1'b1;
    assign vid_ce_pix = 1'b0;
    assign aud_l      = 16'sd0;
    assign aud_r      = 16'sd0;

endmodule

`default_nettype wire
