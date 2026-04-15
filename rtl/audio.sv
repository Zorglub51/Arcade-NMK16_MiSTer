// NMK16 — sound subsystem
// See docs/architecture.md and hardware reference §D + §E.
//
// STUB — not yet implemented. Phase 5 of docs/roadmap.md.
//
// Strategy:
//   Phase 5a: NMK004 HLE — observe latch byte, translate to YM2203/OKI commands.
//   Phase 5b (optional): real TLCS-90 core running nmk004.bin + 1.70.
//
// Chips:
//   YM2203      @ 1.5 MHz (FM 3ch + SSG 3ch)
//   OKIM6295 #1 @ 4 MHz (PIN7 LOW)  with 2-bit external bank
//   OKIM6295 #2 @ 4 MHz (PIN7 LOW)  with 2-bit external bank
//
// Latch interface (with memmap.sv):
//   $08001F W : main -> NMK004     (we receive nmk004_to_snd, nmk004_to_snd_we)
//   $08000F R : NMK004 -> main     (we drive nmk004_to_main)
//   $080016 W b0 : NMK004 NMI gate (watchdog) — drives nmk004_nmi
//
// Optional (Phase 6): protection MCU NMK-113 BUSREQ to 68000 lives here too,
// or in its own module. For now we expose prot_busreq tied low.

`default_nettype none

module audio (
    input  wire        clk_sys,
    input  wire        rst,

    // Clock enables
    input  wire        ce_ym,          // 1.5 MHz
    input  wire        ce_oki,         // 4 MHz

    // Latches with memmap.sv
    input  wire [7:0]  to_snd,         // $08001F write data
    input  wire        to_snd_we,
    output reg  [7:0]  to_main,        // $08000F read data
    input  wire        nmi_gate,       // $080016 b0

    // OKI sample ROMs
    output wire [18:0] oki1_rom_addr,  // 512 KiB
    input  wire [7:0]  oki1_rom_din,
    output wire [18:0] oki2_rom_addr,
    input  wire [7:0]  oki2_rom_din,

    // Main reset (NMK004 watchdog can pull this low if NMI rhythm fails)
    output wire        cpu_reset_req,

    // Protection MCU bus request (tied low until Phase 6)
    output wire        prot_busreq,

    // Audio out
    output wire signed [15:0] aud_l,
    output wire signed [15:0] aud_r
);

    // TODO Phase 5a: HLE state machine that consumes to_snd bytes,
    //                drives YM2203 + OKI command sequences.
    // TODO Phase 5a: instantiate jt03 (YM2203) + 2x jt6295 (OKIM6295).
    // TODO Phase 5a: 2-bit OKI bank registers.
    // TODO Phase 5a: NMK004 watchdog timer — if nmi_gate doesn't toggle in N ms,
    //                assert cpu_reset_req.

    always @(*) to_main = 8'h00;

    assign oki1_rom_addr = '0;
    assign oki2_rom_addr = '0;
    assign cpu_reset_req = 1'b0;
    assign prot_busreq   = 1'b0;
    assign aud_l         = 16'sd0;
    assign aud_r         = 16'sd0;

endmodule

`default_nettype wire
