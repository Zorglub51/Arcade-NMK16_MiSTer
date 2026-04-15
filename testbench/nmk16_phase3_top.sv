// NMK_Core Phase 3 testbench top.
//
// Phase 2 + tilemap.sv + GFX ROMs + palette decoder + VGA out.
// Renders BG (scrolling 16×16 tilemap) and TX (fixed 8×8 text overlay)
// to vga_r/g/b/de/hsync/vsync, sampled by the C++ harness for PPM dump.
//
// What changed from Phase 2:
//   - GFX ROMs loaded ($readmemh, byte-per-line)
//   - tilemap.sv instance reads VRAM + GFX, outputs per-layer pixel info
//   - palette decoder (RRRRGGGGBBBBRGBx → 5b per channel, top 8 used)
//   - mixer: BG opaque base, then TX where pen != 15
//   - VGA timing strobes from irq.sv

`default_nettype none

module nmk16_phase3_top (
    input  wire        clk,
    input  wire        rst,

    // Per-frame stimulus
    input  wire [7:0]  in0_keys,
    input  wire [15:0] in1_keys,
    input  wire [7:0]  dsw1,
    input  wire [7:0]  dsw2,

    // Trace probes
    output wire [23:1] cpu_addr,
    output wire        cpu_as_n,
    output wire [2:0]  cpu_fc,
    output wire [2:0]  irq_ipl,
    output wire        irq_ack_pulse,
    output wire [8:0]  vpos_out,
    output wire [8:0]  hpos_out,

    // VGA out (8b per channel)
    output wire [7:0]  vga_r,
    output wire [7:0]  vga_g,
    output wire [7:0]  vga_b,
    output wire        vga_hsync,
    output wire        vga_vsync,
    output wire        vga_de
);

    // -----------------------------------------------------------------
    // Clock enables
    // -----------------------------------------------------------------
    reg phi_toggle;
    always @(posedge clk) begin
        if (rst) phi_toggle <= 1'b0;
        else     phi_toggle <= ~phi_toggle;
    end
    wire enPhi1 = ~phi_toggle;
    wire enPhi2 =  phi_toggle;

    localparam int PIX_DIV = 16;
    reg [7:0] pix_cnt;
    always @(posedge clk) begin
        if (rst)                       pix_cnt <= 8'd0;
        else if (pix_cnt == PIX_DIV-1) pix_cnt <= 8'd0;
        else                           pix_cnt <= pix_cnt + 8'd1;
    end
    wire ce_pix = (pix_cnt == 8'd0);

    // -----------------------------------------------------------------
    // IRQ + video timing
    // -----------------------------------------------------------------
    wire [2:0] ipl;
    wire       sprdma_unused;
    wire       hsync_w, vsync_w, hblank_w, vblank_w;
    wire [8:0] hpos_w, vpos_w;
    reg        irq_ack;

    irq u_irq (
        .clk_sys        (clk),
        .rst            (rst),
        .ce_pix         (ce_pix),
        .hpos           (hpos_w),
        .vpos           (vpos_w),
        .hsync          (hsync_w),
        .vsync          (vsync_w),
        .hblank         (hblank_w),
        .vblank         (vblank_w),
        .ipl            (ipl),
        .irq_ack        (irq_ack),
        .sprdma_trigger (sprdma_unused)
    );

    // -----------------------------------------------------------------
    // CPU instance
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

    // -----------------------------------------------------------------
    // Strobe edges for write capture (Phase 2 lesson: oEdb only valid
    // by the time UDSn/LDSn fall; safe to latch on their rising edge).
    // -----------------------------------------------------------------
    reg uds_d, lds_d;
    always @(posedge clk) begin
        uds_d <= UDSn;
        lds_d <= LDSn;
    end
    wire uds_rising = ~uds_d & UDSn;
    wire lds_rising = ~lds_d & LDSn;

    // -----------------------------------------------------------------
    // ROMs (program + GFX)
    // -----------------------------------------------------------------
    `ifndef ROM_PATH
        `define ROM_PATH "../roms/hachamfb_prog.hex"
    `endif
    `ifndef BG_GFX_PATH
        `define BG_GFX_PATH "../roms/hachamf_bg.hex"
    `endif
    `ifndef TX_GFX_PATH
        `define TX_GFX_PATH "../roms/hachamf_tx.hex"
    `endif

    reg [15:0] rom    [0:131071];
    reg [7:0]  bg_gfx [0:1048575];     // 1 MiB
    reg [7:0]  tx_gfx [0:131071];      //   128 KiB
    initial begin
        $readmemh(`ROM_PATH,    rom);
        $readmemh(`BG_GFX_PATH, bg_gfx);
        $readmemh(`TX_GFX_PATH, tx_gfx);
    end

    // -----------------------------------------------------------------
    // CPU-visible RAMs
    // -----------------------------------------------------------------
    reg [15:0] wram   [0:32767];
    reg [15:0] bgvram [0:8191];
    reg [15:0] txvram [0:1023];
    reg [15:0] palram [0:1023];
    integer i;
    initial begin
        for (i = 0; i < 32768; i = i + 1) wram[i]   = 16'h0000;
        for (i = 0; i < 8192;  i = i + 1) bgvram[i] = 16'h0000;
        for (i = 0; i < 1024;  i = i + 1) txvram[i] = 16'h0000;
        for (i = 0; i < 1024;  i = i + 1) palram[i] = 16'h0000;
    end

    // Region selects
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
    wire [16:0] rom_widx        = eab[17:1];

    // I/O regs
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
            if (is_io_lo) begin
                case (eab[7:1])
                    7'h0A: if (lds_rising) flipscreen    <= oEdb[0];
                    7'h0B: if (lds_rising) nmk004_nmi    <= oEdb[0];
                    7'h0C: if (lds_rising) bgbank        <= oEdb[7:0];
                    7'h0F: if (lds_rising) nmk004_to_snd <= oEdb[7:0];
                    default: ;
                endcase
            end
            if (is_scroll) begin
                case (eab[7:1])
                    7'h00: if (lds_rising) scroll_xh <= oEdb[7:0];
                    7'h01: if (lds_rising) scroll_xl <= oEdb[7:0];
                    7'h02: if (lds_rising) scroll_yh <= oEdb[7:0];
                    7'h03: if (lds_rising) scroll_yl <= oEdb[7:0];
                    default: ;
                endcase
            end
        end
    end

    // VRAM / palette / WRAM writes
    always @(posedge clk) begin
        if (!rst && !eRWn) begin
            if (is_wram) begin
                if (uds_rising) wram[wram_widx_cpu][15:8] <= oEdb[15:8];
                if (lds_rising) wram[wram_widx_cpu][ 7:0] <= oEdb[ 7:0];
            end
            if (is_bgvram) begin
                if (uds_rising) bgvram[bgvram_widx_cpu][15:8] <= oEdb[15:8];
                if (lds_rising) bgvram[bgvram_widx_cpu][ 7:0] <= oEdb[ 7:0];
            end
            if (is_txvram) begin
                if (uds_rising) txvram[txvram_widx_cpu][15:8] <= oEdb[15:8];
                if (lds_rising) txvram[txvram_widx_cpu][ 7:0] <= oEdb[ 7:0];
            end
            if (is_pal) begin
                if (uds_rising) palram[palram_widx_cpu][15:8] <= oEdb[15:8];
                if (lds_rising) palram[palram_widx_cpu][ 7:0] <= oEdb[ 7:0];
            end
        end
    end

    // I/O reads
    reg [15:0] io_rd;
    always @(*) begin
        io_rd = 16'hFFFF;
        if (is_io_lo) begin
            case (eab[7:1])
                7'h00: io_rd = {in0_keys, 8'h00};
                7'h01: io_rd = in1_keys;
                7'h04: io_rd = {8'h00, dsw1};
                7'h05: io_rd = {8'h00, dsw2};
                7'h07: io_rd = 16'h0000;
                default: io_rd = 16'hFFFF;
            endcase
        end
    end

    assign iEdb = is_rom    ? rom[rom_widx]
                : is_wram   ? wram[wram_widx_cpu]
                : is_bgvram ? bgvram[bgvram_widx_cpu]
                : is_txvram ? txvram[txvram_widx_cpu]
                : is_pal    ? palram[palram_widx_cpu]
                : is_io_lo  ? io_rd
                :             16'hFFFF;

    // -----------------------------------------------------------------
    // Tilemap engine — second read port into VRAM and GFX ROMs
    // -----------------------------------------------------------------
    wire [12:0] bgvram_addr_t;
    wire [9:0]  txvram_addr_t;
    wire [19:0] bg_gfx_addr_t;
    wire [16:0] tx_gfx_addr_t;

    wire [15:0] bgvram_dout_t = bgvram[bgvram_addr_t];
    wire [15:0] txvram_dout_t = txvram[txvram_addr_t];
    wire [7:0]  bg_gfx_dout_t = bg_gfx[bg_gfx_addr_t];
    wire [7:0]  tx_gfx_dout_t = tx_gfx[tx_gfx_addr_t];

    wire [3:0] bg_color, bg_pal, tx_color, tx_pal;
    wire       bg_opaque, tx_opaque;

    tilemap u_tilemap (
        .clk_sys     (clk),
        .rst         (rst),
        .ce_pix      (ce_pix),
        .hpos        (hpos_w),
        .vpos        (vpos_w),
        .flipscreen  (flipscreen),
        .bgvram_addr (bgvram_addr_t),
        .bgvram_din  (bgvram_dout_t),
        .txvram_addr (txvram_addr_t),
        .txvram_din  (txvram_dout_t),
        .scroll_xh   (scroll_xh),
        .scroll_xl   (scroll_xl),
        .scroll_yh   (scroll_yh),
        .scroll_yl   (scroll_yl),
        .bgbank      (bgbank),
        .bg_gfx_addr (bg_gfx_addr_t),
        .bg_gfx_din  (bg_gfx_dout_t),
        .tx_gfx_addr (tx_gfx_addr_t),
        .tx_gfx_din  (tx_gfx_dout_t),
        .bg_color    (bg_color),
        .bg_pal      (bg_pal),
        .bg_opaque   (bg_opaque),
        .tx_color    (tx_color),
        .tx_pal      (tx_pal),
        .tx_opaque   (tx_opaque)
    );

    // -----------------------------------------------------------------
    // Mixer: BG (opaque) base, TX overlays where pen != 15.
    // Sprites added in Phase 4.
    //   BG palette base = $000 + bg_pal*16
    //   TX palette base = $200 + tx_pal*16
    // -----------------------------------------------------------------
    wire [9:0] bg_pal_idx = {2'b00, bg_pal, bg_color};               // $000-$0FF
    wire [9:0] tx_pal_idx = {2'b10, tx_pal, tx_color};               // $200-$2FF
    wire [9:0] mix_idx    = tx_opaque ? tx_pal_idx : bg_pal_idx;
    wire       active     = ~vblank_w & ~hblank_w;

    wire [15:0] pal_word = palram[mix_idx];

    // RRRRGGGGBBBBRGBx → 5b per channel (top 4 + LSB ext)
    wire [4:0] r5 = {pal_word[15:12], pal_word[3]};
    wire [4:0] g5 = {pal_word[11: 8], pal_word[2]};
    wire [4:0] b5 = {pal_word[ 7: 4], pal_word[1]};

    // 5b → 8b expansion (replicate top 3 bits for low side)
    assign vga_r = active ? {r5, r5[4:2]} : 8'h00;
    assign vga_g = active ? {g5, g5[4:2]} : 8'h00;
    assign vga_b = active ? {b5, b5[4:2]} : 8'h00;

    assign vga_hsync = hsync_w;
    assign vga_vsync = vsync_w;
    assign vga_de    = active;

    // -----------------------------------------------------------------
    // Trace probes
    // -----------------------------------------------------------------
    assign cpu_addr      = eab;
    assign cpu_as_n      = ASn;
    assign cpu_fc        = FC;
    assign irq_ipl       = ipl;
    assign irq_ack_pulse = irq_ack;
    assign vpos_out      = vpos_w;
    assign hpos_out      = hpos_w;

endmodule

`default_nettype wire
