// NMK16 / Hacha Mecha Fighter core for MiSTer
//
// Extracted from the Verilator Phase 4 testbench top (see ../testbench/ in
// the development repo). All ROM storage is now external — the wrapper
// (`NMK16.sv`, i.e. the MiSTer `emu` module) provides ROM read ports, which
// it can back with BRAM, SDRAM, or DDRAM as the FPGA budget allows.
//
// Internally the core still owns:
//   - fx68k CPU instance
//   - BG VRAM (16 KiB)   — true dual-port M10K, registered read
//   - TX VRAM (2 KiB)    — true dual-port M10K, registered read
//   - Palette RAM (2 KiB)— true dual-port M10K, registered read
//   - Work RAM (64 KiB)  — true dual-port M10K, registered read
//   - Sprite RAM shadow (2 KiB MLAB) DMA'd from wram on sprdma_trigger
//   - tilemap, irq, sprite_line scanline renderer
//
// Memory still expected in top-level (wrapper):
//   - Program ROM       256 KiB  (128 K × 16-bit words, BE)
//   - BG GFX ROM        1 MiB    (byte-wide)
//   - TX GFX ROM        128 KiB  (byte-wide)
//   - Sprite GFX ROM    1 MiB    (byte-wide, byte-pair swapped on load)
//
// ROM interfaces are single-cycle synchronous: wrapper returns data at
// `*_data` on the clock edge after `*_addr` is driven. Higher-latency memories
// (SDRAM/DDRAM) can meet this by sitting behind a small cache — the
// combinational tilemap path does not tolerate multi-cycle latency today and
// will need pipelining for real FPGA timing closure.

`default_nettype none

module nmk16_core (
    input  wire        clk,              // master clock, e.g. 96 MHz
    input  wire        rst,              // synchronous, active-high

    // ------------- controls -------------
    input  wire [7:0]  in0_keys,         // active-low: bits 0..4 = COIN1/2 SVC START1/2
    input  wire [15:0] in1_keys,         // active-low: P1 @ b0..5 , P2 @ b8..13
    input  wire [7:0]  dsw1,
    input  wire [7:0]  dsw2,

    // ------------- program ROM read port (loaded by wrapper) -------------
    output wire [16:0] prog_rom_addr,    // 128K word index
    input  wire [15:0] prog_rom_data,

    // ------------- GFX ROM read ports -------------
    output wire [19:0] bg_gfx_addr,      // 1 MiB
    input  wire [7:0]  bg_gfx_data,
    output wire [16:0] tx_gfx_addr,      // 128 KiB
    input  wire [7:0]  tx_gfx_data,
    // Sprite GFX: req/valid (matches one channel of sdram.sv).
    output wire        spr_gfx_req,
    input  wire        spr_gfx_ack,
    output wire [23:0] spr_gfx_addr,
    input  wire [15:0] spr_gfx_data,
    input  wire        spr_gfx_valid,

    // ------------- video out -------------
    output wire        ce_pix,           // 6 MHz when master = 96 MHz, PIX_DIV=16
    output wire [8:0]  hpos,
    output wire [8:0]  vpos,
    output wire        hsync,            // active-low
    output wire        vsync,            // active-low
    output wire        hblank,
    output wire        vblank,
    output wire [7:0]  vga_r,
    output wire [7:0]  vga_g,
    output wire [7:0]  vga_b,
    output wire        vga_de,

    // ------------- audio out (silent until Phase 5) -------------
    output wire signed [15:0] audio_l,
    output wire signed [15:0] audio_r
);

    // -----------------------------------------------------------------
    // Clock enables — CPU at clk/4 (enPhi1/enPhi2 alternate), pix at clk/PIX_DIV
    // At master=96 MHz and PIX_DIV=16, pix clock is 6 MHz (matches NMK16 real).
    // CPU gets 24 MHz phi-rate (6 MHz bus cycle rate), ~2.5x real rate.
    // -----------------------------------------------------------------
    localparam int PIX_DIV = 16;

    reg phi_toggle;
    always @(posedge clk) begin
        if (rst) phi_toggle <= 1'b0;
        else     phi_toggle <= ~phi_toggle;
    end
    wire enPhi1 = ~phi_toggle;
    wire enPhi2 =  phi_toggle;

    reg [7:0] pix_cnt;
    always @(posedge clk) begin
        if (rst)                       pix_cnt <= 8'd0;
        else if (pix_cnt == PIX_DIV-1) pix_cnt <= 8'd0;
        else                           pix_cnt <= pix_cnt + 8'd1;
    end
    assign ce_pix = (pix_cnt == 8'd0);

    // -----------------------------------------------------------------
    // IRQ + video timing
    // -----------------------------------------------------------------
    wire [2:0] ipl;
    wire       sprdma_trigger;
    reg        irq_ack;
    wire       hsync_w, vsync_w, hblank_w, vblank_w;

    irq u_irq (
        .clk_sys        (clk),
        .rst            (rst),
        .ce_pix         (ce_pix),
        .hpos           (hpos),
        .vpos           (vpos),
        .hsync          (hsync_w),
        .vsync          (vsync_w),
        .hblank         (hblank_w),
        .vblank         (vblank_w),
        .ipl            (ipl),
        .irq_ack        (irq_ack),
        .sprdma_trigger (sprdma_trigger)
    );
    assign hsync  = hsync_w;
    assign vsync  = vsync_w;
    assign hblank = hblank_w;
    assign vblank = vblank_w;

    // -----------------------------------------------------------------
    // CPU
    // -----------------------------------------------------------------
    wire        ASn, UDSn, LDSn, eRWn;
    wire        E_u, VMAn_u;
    wire [2:0]  FC;
    wire        BGn_u, oRESETn_u, oHALTEDn_u;
    wire [15:0] iEdb, oEdb;
    wire [23:1] eab;

    wire is_iack = (FC == 3'b111) && !ASn;
    wire VPAn   = ~is_iack;
    wire DTACKn =  is_iack;
    wire BERRn  = 1'b1, BRn = 1'b1, BGACKn = 1'b1, HALTn = 1'b1;
    wire IPL0n  = ~ipl[0];
    wire IPL1n  = ~ipl[1];
    wire IPL2n  = ~ipl[2];

    fx68k u_cpu (
        .clk(clk), .HALTn(HALTn), .extReset(rst), .pwrUp(rst),
        .enPhi1(enPhi1), .enPhi2(enPhi2),
        .eRWn(eRWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn),
        .E(E_u), .VMAn(VMAn_u),
        .FC0(FC[0]), .FC1(FC[1]), .FC2(FC[2]),
        .BGn(BGn_u), .oRESETn(oRESETn_u), .oHALTEDn(oHALTEDn_u),
        .DTACKn(DTACKn), .VPAn(VPAn), .BERRn(BERRn),
        .BRn(BRn), .BGACKn(BGACKn),
        .IPL0n(IPL0n), .IPL1n(IPL1n), .IPL2n(IPL2n),
        .iEdb(iEdb), .oEdb(oEdb), .eab(eab)
    );

    reg as_d;
    always @(posedge clk) as_d <= ASn;
    wire as_falling = as_d & ~ASn;
    always @(posedge clk) begin
        if (rst) irq_ack <= 1'b0;
        else     irq_ack <= as_falling && is_iack;
    end

    reg uds_d, lds_d;
    always @(posedge clk) begin uds_d <= UDSn; lds_d <= LDSn; end
    wire uds_rising = ~uds_d & UDSn;
    wire lds_rising = ~lds_d & LDSn;

    // -----------------------------------------------------------------
    // Internal RAMs — true dual-port M10K with registered read.
    //
    // Without registered reads, Quartus drops the M10K hint (M10K has no
    // async read port) and materialises every RAM as fabric registers + LUT
    // mux. wram alone is 32768×16 = ~525k flip-flops, which is the root of
    // the multi-GB / multi-hour synthesis blow-up. With registered reads,
    // these infer cleanly as M10K block RAM.
    // -----------------------------------------------------------------
    (* ramstyle = "M10K" *) reg [15:0] wram   [0:32767];   // 64 KiB
    (* ramstyle = "M10K" *) reg [15:0] bgvram [0:8191];    // 16 KiB
    (* ramstyle = "M10K" *) reg [15:0] txvram [0:1023];    //  2 KiB
    (* ramstyle = "M10K" *) reg [15:0] palram [0:1023];    //  2 KiB

    reg [15:0] wram_rdata_cpu;       // port A: CPU read
    reg [15:0] wram_rdata_dma;       // port B: sprite-RAM shadow DMA
    reg [15:0] bgvram_rdata_cpu;     // port A: CPU
    reg [15:0] bgvram_rdata_pix;     // port B: tilemap per-pixel
    reg [15:0] txvram_rdata_cpu;     // port A: CPU
    reg [15:0] txvram_rdata_pix;     // port B: tilemap per-pixel
    reg [15:0] palram_rdata_cpu;     // port A: CPU
    reg [15:0] palram_rdata_pix;     // port B: mixer

    // Sim init — Quartus infers M10K cleared at config; sim needs it explicit.
    `ifdef VERILATOR
    integer ii;
    initial begin
        for (ii = 0; ii < 32768; ii = ii + 1) wram[ii]   = 16'h0000;
        for (ii = 0; ii < 8192;  ii = ii + 1) bgvram[ii] = 16'h0000;
        for (ii = 0; ii < 1024;  ii = ii + 1) txvram[ii] = 16'h0000;
        for (ii = 0; ii < 1024;  ii = ii + 1) palram[ii] = 16'h0000;
    end
    `endif

    // -----------------------------------------------------------------
    // Memory decode
    // -----------------------------------------------------------------
    wire is_rom    = (eab[23:18] == 6'b000000);
    wire is_io_lo  = (eab[23:16] == 8'h08) && (eab[15:8] == 8'h00);
    wire is_pal    = (eab[23:11] == 13'b00001000_1000_0);
    wire is_scroll = (eab[23:8]  == 16'h08C0);
    wire is_bgvram = (eab[23:14] == 10'b0000_1001_00);
    wire is_txvram = (eab[23:11] == 13'b00001001_1100_0);
    wire is_wram   = (eab[23:16] == 8'h0F);

    wire [14:0] wram_widx_cpu   = eab[15:1];
    wire [12:0] bgvram_widx_cpu = eab[13:1];
    wire [9:0]  txvram_widx_cpu = eab[10:1];
    wire [9:0]  palram_widx_cpu = eab[10:1];

    assign prog_rom_addr = eab[17:1];

    // -----------------------------------------------------------------
    // I/O regs (control side)
    // -----------------------------------------------------------------
    reg        flipscreen;
    reg [7:0]  bgbank;
    reg [7:0]  scroll_xh, scroll_xl, scroll_yh, scroll_yl;
    reg [7:0]  nmk004_to_snd;
    reg        nmk004_nmi;

    always @(posedge clk) begin
        if (rst) begin
            flipscreen    <= 1'b0;
            bgbank        <= 8'h00;
            scroll_xh     <= 8'h00; scroll_xl <= 8'h00;
            scroll_yh     <= 8'h00; scroll_yl <= 8'h00;
            nmk004_to_snd <= 8'h00;
            nmk004_nmi    <= 1'b0;
        end else if (!eRWn && (uds_rising || lds_rising)) begin
            if (is_io_lo) case (eab[7:1])
                7'h0A: if (lds_rising) flipscreen    <= oEdb[0];
                7'h0B: if (lds_rising) nmk004_nmi    <= oEdb[0];
                7'h0C: if (lds_rising) bgbank        <= oEdb[7:0];
                7'h0F: if (lds_rising) nmk004_to_snd <= oEdb[7:0];
                default: ;
            endcase
            if (is_scroll) case (eab[7:1])
                7'h00: if (lds_rising) scroll_xh <= oEdb[7:0];
                7'h01: if (lds_rising) scroll_xl <= oEdb[7:0];
                7'h02: if (lds_rising) scroll_yh <= oEdb[7:0];
                7'h03: if (lds_rising) scroll_yl <= oEdb[7:0];
                default: ;
            endcase
        end
    end

    // RAM read+write blocks — one per port, structured the way Quartus
    // recognises as M10K. Forward-referenced wires (bgvram_addr_t,
    // txvram_addr_t, mix_idx, dma_wram_addr) are declared further down.
    always @(posedge clk) begin
        if (!rst && !eRWn && is_wram) begin
            if (uds_rising) wram[wram_widx_cpu][15:8] <= oEdb[15:8];
            if (lds_rising) wram[wram_widx_cpu][ 7:0] <= oEdb[ 7:0];
        end
        wram_rdata_cpu <= wram[wram_widx_cpu];
    end
    always @(posedge clk) wram_rdata_dma <= wram[dma_wram_addr];

    always @(posedge clk) begin
        if (!rst && !eRWn && is_bgvram) begin
            if (uds_rising) bgvram[bgvram_widx_cpu][15:8] <= oEdb[15:8];
            if (lds_rising) bgvram[bgvram_widx_cpu][ 7:0] <= oEdb[ 7:0];
        end
        bgvram_rdata_cpu <= bgvram[bgvram_widx_cpu];
    end
    always @(posedge clk) bgvram_rdata_pix <= bgvram[bgvram_addr_t];

    always @(posedge clk) begin
        if (!rst && !eRWn && is_txvram) begin
            if (uds_rising) txvram[txvram_widx_cpu][15:8] <= oEdb[15:8];
            if (lds_rising) txvram[txvram_widx_cpu][ 7:0] <= oEdb[ 7:0];
        end
        txvram_rdata_cpu <= txvram[txvram_widx_cpu];
    end
    always @(posedge clk) txvram_rdata_pix <= txvram[txvram_addr_t];

    always @(posedge clk) begin
        if (!rst && !eRWn && is_pal) begin
            if (uds_rising) palram[palram_widx_cpu][15:8] <= oEdb[15:8];
            if (lds_rising) palram[palram_widx_cpu][ 7:0] <= oEdb[ 7:0];
        end
        palram_rdata_cpu <= palram[palram_widx_cpu];
    end
    always @(posedge clk) palram_rdata_pix <= palram[mix_idx];

    // I/O read mux
    reg [15:0] io_rd;
    always @(*) begin
        io_rd = 16'hFFFF;
        if (is_io_lo) case (eab[7:1])
            7'h00: io_rd = {in0_keys, in0_keys};
            7'h01: io_rd = in1_keys;
            7'h04: io_rd = {dsw1, dsw1};
            7'h05: io_rd = {dsw2, dsw2};
            7'h07: io_rd = {nmk004_to_snd, nmk004_to_snd};   // echo-ack stub
            default: io_rd = 16'hFFFF;
        endcase
    end

    // 1-cycle BRAM read latency — within fx68k bus-cycle slack at clk=96 MHz
    // (CPU bus phase is ~16 clk; the same pattern is already used for
    // prog_rom in the wrapper).
    assign iEdb = is_rom    ? prog_rom_data
                : is_wram   ? wram_rdata_cpu
                : is_bgvram ? bgvram_rdata_cpu
                : is_txvram ? txvram_rdata_cpu
                : is_pal    ? palram_rdata_cpu
                : is_io_lo  ? io_rd
                :             16'hFFFF;

    // -----------------------------------------------------------------
    // Tilemap (BG + TX)
    // -----------------------------------------------------------------
    wire [12:0] bgvram_addr_t;
    wire [9:0]  txvram_addr_t;
    wire [3:0]  bg_color, bg_pal, tx_color, tx_pal;
    wire        bg_opaque_u, tx_opaque;

    tilemap u_tilemap (
        .clk_sys(clk), .rst(rst), .ce_pix(ce_pix),
        .hpos(hpos), .vpos(vpos), .flipscreen(flipscreen),
        .bgvram_addr(bgvram_addr_t), .bgvram_din(bgvram_rdata_pix),
        .txvram_addr(txvram_addr_t), .txvram_din(txvram_rdata_pix),
        .scroll_xh(scroll_xh), .scroll_xl(scroll_xl),
        .scroll_yh(scroll_yh), .scroll_yl(scroll_yl),
        .bgbank(bgbank),
        .bg_gfx_addr(bg_gfx_addr), .bg_gfx_din(bg_gfx_data),
        .tx_gfx_addr(tx_gfx_addr), .tx_gfx_din(tx_gfx_data),
        .bg_color(bg_color), .bg_pal(bg_pal), .bg_opaque(bg_opaque_u),
        .tx_color(tx_color), .tx_pal(tx_pal), .tx_opaque(tx_opaque)
    );

    // -----------------------------------------------------------------
    // Sprite engine — scanline renderer (rtl/sprite_line.sv).
    //
    // The previous design had a 256×224×16-bit "frame buffer" array
    // (~57k entries) read combinationally by the mixer. With async read,
    // Quartus dropped the M10K hint and built it out of fabric registers
    // — that single array dominated the synthesis blow-up.
    //
    // The scanline renderer keeps two 256×16 line buffers and walks
    // sprite RAM once per scanline. Total state: 512 × 16 = 8 Kib, fits
    // in two M10K blocks.
    //
    // Sprite RAM (CPU $F8000–$F8FFF, mirrored at wram[$4000..$47FF]) is
    // shadowed into a 2 KiB MLAB on `sprdma_trigger` so the engine reads
    // a stable copy while the CPU writes the next frame's table — this
    // matches real NMK16 DMA timing.
    // -----------------------------------------------------------------

    // ---- DMA shadow: wram[$4000..$47FF] → spr_ram_shadow ----
    // MLAB ramstyle: async read so sprite_line's same-cycle data model
    // works without modification. 2048×16 bits ≈ 64 MLAB cells — trivial.
    (* ramstyle = "MLAB" *) reg [15:0] spr_ram_shadow [0:2047];
    `ifdef VERILATOR
    integer kk;
    initial for (kk = 0; kk < 2048; kk = kk + 1) spr_ram_shadow[kk] = 16'h0000;
    `endif

    reg        dma_busy;
    reg [11:0] dma_rd_idx;     // 0..2048 (one extra to drain pipeline)
    reg [10:0] dma_wr_idx;
    reg        dma_wr_valid;

    // wram port-B address (sprite-RAM region: $4000 + idx)
    wire [14:0] dma_wram_addr = {4'b0100, dma_rd_idx[10:0]};

    always @(posedge clk) begin
        if (rst) begin
            dma_busy     <= 1'b0;
            dma_rd_idx   <= 12'd0;
            dma_wr_valid <= 1'b0;
        end else begin
            // Trigger pulse starts a copy if not already busy.
            if (sprdma_trigger && !dma_busy) begin
                dma_busy     <= 1'b1;
                dma_rd_idx   <= 12'd0;
                dma_wr_valid <= 1'b0;
            end else if (dma_busy) begin
                // wr_valid follows rd_idx with one cycle of latency to
                // match the M10K read pipeline (addr → wram_rdata_dma).
                dma_wr_idx   <= dma_rd_idx[10:0];
                dma_wr_valid <= (dma_rd_idx < 12'd2048);

                if (dma_rd_idx == 12'd2048) begin
                    // Last entry written this cycle; done.
                    dma_busy     <= 1'b0;
                    dma_wr_valid <= 1'b0;
                end else begin
                    dma_rd_idx <= dma_rd_idx + 12'd1;
                end
            end
        end
    end

    // Shadow write — fed by registered wram_rdata_dma (1-cycle pipeline).
    always @(posedge clk) begin
        if (dma_wr_valid) spr_ram_shadow[dma_wr_idx] <= wram_rdata_dma;
    end

    // ---- sprite_line instance ----
    wire [14:0] spr_ram_addr_w;
    wire [15:0] spr_ram_data_w = spr_ram_shadow[spr_ram_addr_w[10:0]];
    wire [9:0]  spr_pal_idx_px;
    wire        spr_opaque_px;

    sprite_line u_sprite (
        .clk          (clk),
        .rst          (rst),
        .ce_pix       (ce_pix),
        .hpos         (hpos),
        .vpos         (vpos),
        .spr_ram_addr (spr_ram_addr_w),
        .spr_ram_data (spr_ram_data_w),
        .spr_gfx_req  (spr_gfx_req),
        .spr_gfx_ack  (spr_gfx_ack),
        .spr_gfx_addr (spr_gfx_addr),
        .spr_gfx_data (spr_gfx_data),
        .spr_gfx_valid(spr_gfx_valid),
        .spr_pal_idx  (spr_pal_idx_px),
        .spr_opaque   (spr_opaque_px)
    );

    // -----------------------------------------------------------------
    // Mixer + palette lookup → vga_r/g/b
    // -----------------------------------------------------------------
    // Sprite output (spr_pal_idx_px / spr_opaque_px) comes from sprite_line
    // above. Palette read goes through the registered palram_rdata_pix port
    // (1-cycle latency), so vga_r/g/b lag the mix index by one master clock
    // — well within ce_pix slack at PIX_DIV=16.
    wire [9:0] bg_pal_idx = {2'b00, bg_pal, bg_color};
    wire [9:0] tx_pal_idx = {2'b10, tx_pal, tx_color};
    wire [9:0] mix_idx    = tx_opaque     ? tx_pal_idx
                          : spr_opaque_px ? spr_pal_idx_px
                          :                 bg_pal_idx;
    wire       active     = ~vblank_w & ~hblank_w;

    wire [15:0] pal_word = palram_rdata_pix;
    wire [4:0] r5 = {pal_word[15:12], pal_word[3]};
    wire [4:0] g5 = {pal_word[11: 8], pal_word[2]};
    wire [4:0] b5 = {pal_word[ 7: 4], pal_word[1]};

    assign vga_r = active ? {r5, r5[4:2]} : 8'h00;
    assign vga_g = active ? {g5, g5[4:2]} : 8'h00;
    assign vga_b = active ? {b5, b5[4:2]} : 8'h00;
    assign vga_de = active;

    // Audio — silent stub until Phase 5 (jt03 + jt6295 + NMK004 HLE)
    assign audio_l = 16'sd0;
    assign audio_r = 16'sd0;

endmodule

`default_nettype wire
