// NMK16 / Hacha Mecha Fighter core for MiSTer
//
// Extracted from the Verilator Phase 4 testbench top (see ../testbench/ in
// the development repo). All ROM storage is now external — the wrapper
// (`NMK16.sv`, i.e. the MiSTer `emu` module) provides ROM read ports, which
// it can back with BRAM, SDRAM, or DDRAM as the FPGA budget allows.
//
// Internally the core still owns:
//   - fx68k CPU instance
//   - BG VRAM (16 KiB)
//   - TX VRAM (2 KiB)
//   - Palette RAM (2 KiB)
//   - Work RAM (64 KiB)
//   - Sprite framebuffer (256 × 224 × 16 bit)
//   - tilemap, irq, sprite FSM
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
    output wire [19:0] spr_gfx_addr,     // 1 MiB
    input  wire [7:0]  spr_gfx_data,

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
    // Internal RAMs
    // -----------------------------------------------------------------
    (* ramstyle = "M10K" *) reg [15:0] wram   [0:32767];   // 64 KiB
    (* ramstyle = "M10K" *) reg [15:0] bgvram [0:8191];    // 16 KiB
    (* ramstyle = "M10K" *) reg [15:0] txvram [0:1023];    //  2 KiB
    (* ramstyle = "M10K" *) reg [15:0] palram [0:1023];    //  2 KiB

    // Quartus infers M10K BRAMs initialized to 0 by default.
    // Verilator needs explicit initialization.
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

    assign iEdb = is_rom    ? prog_rom_data
                : is_wram   ? wram[wram_widx_cpu]
                : is_bgvram ? bgvram[bgvram_widx_cpu]
                : is_txvram ? txvram[txvram_widx_cpu]
                : is_pal    ? palram[palram_widx_cpu]
                : is_io_lo  ? io_rd
                :             16'hFFFF;

    // -----------------------------------------------------------------
    // Tilemap (BG + TX)
    // -----------------------------------------------------------------
    wire [12:0] bgvram_addr_t;
    wire [9:0]  txvram_addr_t;
    wire [15:0] bgvram_dout_t = bgvram[bgvram_addr_t];
    wire [15:0] txvram_dout_t = txvram[txvram_addr_t];
    wire [3:0]  bg_color, bg_pal, tx_color, tx_pal;
    wire        bg_opaque_u, tx_opaque;

    tilemap u_tilemap (
        .clk_sys(clk), .rst(rst), .ce_pix(ce_pix),
        .hpos(hpos), .vpos(vpos), .flipscreen(flipscreen),
        .bgvram_addr(bgvram_addr_t), .bgvram_din(bgvram_dout_t),
        .txvram_addr(txvram_addr_t), .txvram_din(txvram_dout_t),
        .scroll_xh(scroll_xh), .scroll_xl(scroll_xl),
        .scroll_yh(scroll_yh), .scroll_yl(scroll_yl),
        .bgbank(bgbank),
        .bg_gfx_addr(bg_gfx_addr), .bg_gfx_din(bg_gfx_data),
        .tx_gfx_addr(tx_gfx_addr), .tx_gfx_din(tx_gfx_data),
        .bg_color(bg_color), .bg_pal(bg_pal), .bg_opaque(bg_opaque_u),
        .tx_color(tx_color), .tx_pal(tx_pal), .tx_opaque(tx_opaque)
    );

    // -----------------------------------------------------------------
    // Sprite engine — inline FSM walks 256 entries ×16 B from workram
    // -----------------------------------------------------------------
    localparam int FB_W  = 256;
    localparam int FB_H  = 224;
    localparam int FB_SZ = FB_W * FB_H;

    (* ramstyle = "M10K" *) reg [15:0] spr_fb [0:FB_SZ-1];
    `ifdef VERILATOR
    integer jj;
    initial for (jj = 0; jj < FB_SZ; jj = jj + 1) spr_fb[jj] = 16'h0000;
    `endif

    localparam [2:0] S_IDLE  = 3'd0, S_CLEAR = 3'd1,
                     S_READ  = 3'd2, S_DRAW  = 3'd3, S_NEXT = 3'd4;

    reg [2:0]  sp_state;
    reg [15:0] clear_idx;
    reg [7:0]  sprite_idx;
    reg [8:0]  sp_x, sp_y;
    reg [15:0] sp_code;
    reg [3:0]  sp_pal, sp_w_tiles, sp_h_tiles;
    reg [3:0]  tile_x_cnt, tile_y_cnt, px_x, px_y;

    wire [15:0] cur_tile_code = sp_code
                              + {12'd0, tile_y_cnt} * ({12'd0, sp_w_tiles} + 16'd1)
                              + {12'd0, tile_x_cnt};
    assign spr_gfx_addr = {cur_tile_code[12:0], px_x[3], px_y[3],
                           px_y[2:0], px_x[2:1]};
    wire [7:0]  cur_gfx_byte = spr_gfx_data;
    wire [3:0]  cur_pixel    = px_x[0] ? cur_gfx_byte[3:0] : cur_gfx_byte[7:4];
    wire        cur_opaque   = (cur_pixel != 4'hF);

    wire [15:0] cur_screen_x_u = {7'd0, sp_x}
                               + {8'd0, tile_x_cnt, 4'b0}
                               + {12'd0, px_x};
    wire [15:0] cur_screen_y_u = {7'd0, sp_y}
                               + {8'd0, tile_y_cnt, 4'b0}
                               + {12'd0, px_y};
    wire        in_bounds     = (cur_screen_x_u < FB_W) &&
                                (cur_screen_y_u < FB_H);
    wire [15:0] fb_addr       = cur_screen_y_u * 16'(FB_W) + cur_screen_x_u;

    wire [14:0] spr_src_base  = 15'h4000 + {sprite_idx, 3'b000};
    wire [15:0] sp_word0 = wram[spr_src_base + 15'd0];
    wire [15:0] sp_word1 = wram[spr_src_base + 15'd1];
    wire [15:0] sp_word3 = wram[spr_src_base + 15'd3];
    wire [15:0] sp_word4 = wram[spr_src_base + 15'd4];
    wire [15:0] sp_word6 = wram[spr_src_base + 15'd6];
    wire [15:0] sp_word7 = wram[spr_src_base + 15'd7];
    wire sp_enabled = sp_word0[0];

    always @(posedge clk) begin
        if (rst) begin
            sp_state   <= S_IDLE;
            clear_idx  <= 16'd0;
            sprite_idx <= 8'd0;
            sp_x <= 9'd0; sp_y <= 9'd0; sp_code <= 16'd0; sp_pal <= 4'd0;
            sp_w_tiles <= 4'd0; sp_h_tiles <= 4'd0;
            tile_x_cnt <= 4'd0; tile_y_cnt <= 4'd0;
            px_x <= 4'd0; px_y <= 4'd0;
        end else begin
            case (sp_state)
                S_IDLE:
                    if (sprdma_trigger) begin sp_state <= S_CLEAR; clear_idx <= 16'd0; end
                S_CLEAR: begin
                    spr_fb[clear_idx] <= 16'h0000;
                    if (clear_idx == 16'(FB_SZ-1)) begin
                        sp_state <= S_READ; sprite_idx <= 8'd0;
                    end else clear_idx <= clear_idx + 16'd1;
                end
                S_READ: begin
                    sp_x <= sp_word4[8:0]; sp_y <= sp_word6[8:0];
                    sp_code <= sp_word3; sp_pal <= sp_word7[3:0];
                    sp_w_tiles <= sp_word1[3:0]; sp_h_tiles <= sp_word1[7:4];
                    tile_x_cnt <= 4'd0; tile_y_cnt <= 4'd0;
                    px_x <= 4'd0; px_y <= 4'd0;
                    sp_state <= sp_enabled ? S_DRAW : S_NEXT;
                end
                S_DRAW: begin
                    if (in_bounds && cur_opaque)
                        spr_fb[fb_addr] <= {1'b1, 5'b0, 2'b01, sp_pal, cur_pixel};
                    if (px_x != 4'd15) px_x <= px_x + 4'd1;
                    else begin
                        px_x <= 4'd0;
                        if (px_y != 4'd15) px_y <= px_y + 4'd1;
                        else begin
                            px_y <= 4'd0;
                            if (tile_x_cnt != sp_w_tiles) tile_x_cnt <= tile_x_cnt + 4'd1;
                            else begin
                                tile_x_cnt <= 4'd0;
                                if (tile_y_cnt != sp_h_tiles) tile_y_cnt <= tile_y_cnt + 4'd1;
                                else sp_state <= S_NEXT;
                            end
                        end
                    end
                end
                S_NEXT:
                    if (sprite_idx == 8'd255) sp_state <= S_IDLE;
                    else begin sprite_idx <= sprite_idx + 8'd1; sp_state <= S_READ; end
                default: sp_state <= S_IDLE;
            endcase
        end
    end

    // -----------------------------------------------------------------
    // Mixer + palette lookup → vga_r/g/b
    // -----------------------------------------------------------------
    wire [11:0] screen_x = {3'b0, hpos} - 12'd92;
    wire [11:0] screen_y = {3'b0, vpos} - 12'd16;
    wire        in_active = (screen_x < 12'(FB_W)) && (screen_y < 12'(FB_H));
    wire [15:0] spr_fb_addr2 = screen_y[7:0] * 16'(FB_W) + {8'd0, screen_x[7:0]};
    wire [15:0] spr_px = in_active ? spr_fb[spr_fb_addr2] : 16'h0000;
    wire        spr_opaque_px = spr_px[15];
    wire [9:0]  spr_pal_idx_px= spr_px[9:0];

    wire [9:0] bg_pal_idx = {2'b00, bg_pal, bg_color};
    wire [9:0] tx_pal_idx = {2'b10, tx_pal, tx_color};
    wire [9:0] mix_idx    = tx_opaque     ? tx_pal_idx
                          : spr_opaque_px ? spr_pal_idx_px
                          :                 bg_pal_idx;
    wire       active     = ~vblank_w & ~hblank_w;

    wire [15:0] pal_word = palram[mix_idx];
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
