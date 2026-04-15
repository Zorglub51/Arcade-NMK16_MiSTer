// NMK_Core Phase 4 testbench top.
//
// Phase 3 (BG + TX tilemaps) + sprite engine with DMA + sprite framebuffer.
// Triggered by irq.sv's sprdma pulse (line 242). Clears a 256×224 sprite
// framebuffer, then walks 256 sprites from workram $0F8000–$0F8FFF, drawing
// each into the framebuffer one pixel per clock. Mixer now: BG < sprite < TX.
//
// Simplifications vs. real hardware:
//   - DMA doesn't halt the CPU (no BUSREQ) — real HW stalls CPU for ~694 µs.
//   - No double-buffer — sprite engine reads workram directly. OK because we
//     render during VBLANK, when the CPU is typically waiting in the main-
//     loop IRQ handler and not mutating spriteram.
//   - flipscreen / sprite flipX/flipY ignored (hachamf driver doesn't set them).
//   - Sprite X-wrap at 512 clipped instead of wrapped (on-screen sprites only).
//
// Transparent pixel: sprite pen 0 (common arcade convention). Will confirm
// empirically — if sprites render with a black box around them, we'll know.

`default_nettype none

module nmk16_phase4_top (
    input  wire        clk,
    input  wire        rst,

    input  wire [7:0]  in0_keys,
    input  wire [15:0] in1_keys,
    input  wire [7:0]  dsw1,
    input  wire [7:0]  dsw2,

    output wire [23:1] cpu_addr,
    output wire        cpu_as_n,
    output wire        cpu_uds_n_o,
    output wire        cpu_lds_n_o,
    output wire        cpu_rw,            // 1=read, 0=write
    output wire [15:0] cpu_din,
    output wire [15:0] cpu_dout,
    output wire [2:0]  cpu_fc,
    output wire [2:0]  irq_ipl,
    output wire        irq_ack_pulse,
    output wire [8:0]  vpos_out,
    output wire [8:0]  hpos_out,

    output wire [7:0]  vga_r,
    output wire [7:0]  vga_g,
    output wire [7:0]  vga_b,
    output wire        vga_hsync,
    output wire        vga_vsync,
    output wire        vga_de
);

    // -----------------------------------------------------------------
    // Clock enables (same scheme as Phase 3)
    // -----------------------------------------------------------------
    reg phi_toggle;
    always @(posedge clk) begin
        if (rst) phi_toggle <= 1'b0;
        else     phi_toggle <= ~phi_toggle;
    end
    wire enPhi1 = ~phi_toggle;
    wire enPhi2 =  phi_toggle;

    `ifndef PIX_DIV_VAL
        `define PIX_DIV_VAL 16
    `endif
    localparam int PIX_DIV = `PIX_DIV_VAL;
    reg [7:0] pix_cnt;
    always @(posedge clk) begin
        if (rst)                       pix_cnt <= 8'd0;
        else if (pix_cnt == PIX_DIV-1) pix_cnt <= 8'd0;
        else                           pix_cnt <= pix_cnt + 8'd1;
    end
    wire ce_pix = (pix_cnt == 8'd0);

    // -----------------------------------------------------------------
    // IRQ + sprdma pulse
    // -----------------------------------------------------------------
    wire [2:0] ipl;
    wire       sprdma_trigger;
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
        .sprdma_trigger (sprdma_trigger)
    );

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
    always @(posedge clk) begin
        uds_d <= UDSn;
        lds_d <= LDSn;
    end
    wire uds_rising = ~uds_d & UDSn;
    wire lds_rising = ~lds_d & LDSn;

    // -----------------------------------------------------------------
    // ROMs — loaded via $fread on binary files (10-50× faster than
    // $readmemh for multi-MB files). Requires Makefile to produce
    // .bin alongside .hex via build_hachamfb_hex.py.
    // -----------------------------------------------------------------
    `ifndef ROM_BIN
        `define ROM_BIN "../roms/hachamfb_prog.bin"
    `endif
    `ifndef BG_GFX_BIN
        `define BG_GFX_BIN "../roms/hachamf_bg.bin"
    `endif
    `ifndef TX_GFX_BIN
        `define TX_GFX_BIN "../roms/hachamf_tx.bin"
    `endif
    `ifndef SPR_GFX_BIN
        `define SPR_GFX_BIN "../roms/hachamf_spr.bin"
    `endif

    reg [15:0] rom     [0:131071];
    reg [7:0]  bg_gfx  [0:1048575];
    reg [7:0]  tx_gfx  [0:131071];
    reg [7:0]  spr_gfx [0:1048575];

    // Helper task to load a binary file into any $fread-compatible array.
    // $fread on a reg [W-1:0] arr[N] reads N*ceil(W/8) bytes, MSB-first
    // within each element. .bin files are big-endian-per-element by build.
    integer fd_init;
    initial begin
        fd_init = $fopen(`ROM_BIN, "rb");
        if (fd_init == 0) $display("ERROR: can't open %s", `ROM_BIN);
        else begin void'($fread(rom, fd_init)); $fclose(fd_init); end

        fd_init = $fopen(`BG_GFX_BIN, "rb");
        if (fd_init == 0) $display("ERROR: can't open %s", `BG_GFX_BIN);
        else begin void'($fread(bg_gfx, fd_init)); $fclose(fd_init); end

        fd_init = $fopen(`TX_GFX_BIN, "rb");
        if (fd_init == 0) $display("ERROR: can't open %s", `TX_GFX_BIN);
        else begin void'($fread(tx_gfx, fd_init)); $fclose(fd_init); end

        fd_init = $fopen(`SPR_GFX_BIN, "rb");
        if (fd_init == 0) $display("ERROR: can't open %s", `SPR_GFX_BIN);
        else begin void'($fread(spr_gfx, fd_init)); $fclose(fd_init); end
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

    reg [15:0] io_rd;
    always @(*) begin
        io_rd = 16'hFFFF;
        if (is_io_lo) case (eab[7:1])
            // IN0 lives in low byte per MAME port def (bits 0..4 = COIN1/2/SVC/START1/2).
            // Mirror on both bytes so byte-read to either address works.
            7'h00: io_rd = {in0_keys, in0_keys};
            7'h01: io_rd = in1_keys;
            7'h04: io_rd = {dsw1, dsw1};
            7'h05: io_rd = {dsw2, dsw2};
            // NMK004 -> main latch at $08000F: echo the last byte written to
            // $08001F. That's enough to satisfy the sound-queue handler at
            // $04A2 (CMP.B $08000F,D3; BEQ skip_send; RTS).
            7'h07: io_rd = {nmk004_to_snd, nmk004_to_snd};
            default: io_rd = 16'hFFFF;
        endcase
    end

    assign iEdb = is_rom    ? rom[rom_widx]
                : is_wram   ? wram[wram_widx_cpu]
                : is_bgvram ? bgvram[bgvram_widx_cpu]
                : is_txvram ? txvram[txvram_widx_cpu]
                : is_pal    ? palram[palram_widx_cpu]
                : is_io_lo  ? io_rd
                :             16'hFFFF;

    // -----------------------------------------------------------------
    // Tilemap engine (BG + TX), same as Phase 3
    // -----------------------------------------------------------------
    wire [12:0] bgvram_addr_t;
    wire [9:0]  txvram_addr_t;
    wire [19:0] bg_gfx_addr_t;
    wire [16:0] tx_gfx_addr_t;
    wire [15:0] bgvram_dout_t = bgvram[bgvram_addr_t];
    wire [15:0] txvram_dout_t = txvram[txvram_addr_t];
    wire [7:0]  bg_gfx_dout_t = bg_gfx[bg_gfx_addr_t];
    wire [7:0]  tx_gfx_dout_t = tx_gfx[tx_gfx_addr_t];
    wire [3:0]  bg_color, bg_pal, tx_color, tx_pal;
    wire        bg_opaque_u, tx_opaque;

    tilemap u_tilemap (
        .clk_sys(clk), .rst(rst), .ce_pix(ce_pix),
        .hpos(hpos_w), .vpos(vpos_w), .flipscreen(flipscreen),
        .bgvram_addr(bgvram_addr_t), .bgvram_din(bgvram_dout_t),
        .txvram_addr(txvram_addr_t), .txvram_din(txvram_dout_t),
        .scroll_xh(scroll_xh), .scroll_xl(scroll_xl),
        .scroll_yh(scroll_yh), .scroll_yl(scroll_yl),
        .bgbank(bgbank),
        .bg_gfx_addr(bg_gfx_addr_t), .bg_gfx_din(bg_gfx_dout_t),
        .tx_gfx_addr(tx_gfx_addr_t), .tx_gfx_din(tx_gfx_dout_t),
        .bg_color(bg_color), .bg_pal(bg_pal), .bg_opaque(bg_opaque_u),
        .tx_color(tx_color), .tx_pal(tx_pal), .tx_opaque(tx_opaque)
    );

    // -----------------------------------------------------------------
    // Sprite engine — single buffer, trigger on sprdma_trigger.
    // State machine: IDLE -> CLEAR -> READ -> DRAW -> (next sprite or IDLE)
    // -----------------------------------------------------------------
    localparam int FB_W  = 256;
    localparam int FB_H  = 224;
    localparam int FB_SZ = FB_W * FB_H;          // 57344

    // spr_fb[]: bit 15 = opaque, bits [9:0] = 10-bit palette index
    reg [15:0] spr_fb [0:FB_SZ-1];
    integer k;
    initial for (k = 0; k < FB_SZ; k = k + 1) spr_fb[k] = 16'h0000;

    localparam [2:0] S_IDLE  = 3'd0,
                     S_CLEAR = 3'd1,
                     S_READ  = 3'd2,
                     S_DRAW  = 3'd3,
                     S_NEXT  = 3'd4;

    reg [2:0]  sp_state;
    reg [15:0] clear_idx;
    reg [7:0]  sprite_idx;

    // Latched sprite attrs (for the sprite currently being drawn)
    reg [8:0]  sp_x;
    reg [8:0]  sp_y;
    reg [15:0] sp_code;
    reg [3:0]  sp_pal;
    reg [3:0]  sp_w_tiles;      // 0..15 (width-1)
    reg [3:0]  sp_h_tiles;      // 0..15
    reg [3:0]  tile_x_cnt;      // 0..sp_w_tiles
    reg [3:0]  tile_y_cnt;      // 0..sp_h_tiles
    reg [3:0]  px_x;            // 0..15 within tile
    reg [3:0]  px_y;            // 0..15

    // Derived for current pixel
    wire [15:0] cur_tile_code = sp_code
                              + {12'd0, tile_y_cnt} * ({12'd0, sp_w_tiles} + 16'd1)
                              + {12'd0, tile_x_cnt};
    wire [19:0] cur_gfx_addr  = {cur_tile_code[12:0], px_x[3], px_y[3],
                                 px_y[2:0], px_x[2:1]};
    wire [7:0]  cur_gfx_byte  = spr_gfx[cur_gfx_addr];
    wire [3:0]  cur_pixel     = px_x[0] ? cur_gfx_byte[3:0] : cur_gfx_byte[7:4];
    // Sprite transparency: NMK16 uses pen 15 as transparent (verified
    // empirically — pen 0 gave a solid rectangle of sprite palette entry 0
    // around each sprite, which is how Phase 4 initially rendered).
    wire        cur_opaque    = (cur_pixel != 4'hF);

    wire [15:0] cur_screen_x_u = {7'd0, sp_x}
                               + {8'd0, tile_x_cnt, 4'b0}
                               + {12'd0, px_x};
    wire [15:0] cur_screen_y_u = {7'd0, sp_y}
                               + {8'd0, tile_y_cnt, 4'b0}
                               + {12'd0, px_y};
    wire        in_bounds     = (cur_screen_x_u < FB_W) &&
                                (cur_screen_y_u < FB_H);
    wire [15:0] fb_addr       = cur_screen_y_u * 16'(FB_W) + cur_screen_x_u;

    // One sprite = 8 words in workram, located at word index $4000 + idx*8
    wire [14:0] spr_src_base  = 15'h4000 + {sprite_idx, 3'b000};

    // Read sprite attrs in a single cycle (all combinational from wram[])
    wire [15:0] sp_word0 = wram[spr_src_base + 15'd0];   // +0 enable bit 0
    wire [15:0] sp_word1 = wram[spr_src_base + 15'd1];   // +2 size + flip
    wire [15:0] sp_word3 = wram[spr_src_base + 15'd3];   // +6 code
    wire [15:0] sp_word4 = wram[spr_src_base + 15'd4];   // +8 X
    wire [15:0] sp_word6 = wram[spr_src_base + 15'd6];   // +12 Y
    wire [15:0] sp_word7 = wram[spr_src_base + 15'd7];   // +14 palette

    wire sp_enabled = sp_word0[0];

    always @(posedge clk) begin
        if (rst) begin
            sp_state   <= S_IDLE;
            clear_idx  <= 16'd0;
            sprite_idx <= 8'd0;
            sp_x       <= 9'd0;
            sp_y       <= 9'd0;
            sp_code    <= 16'd0;
            sp_pal     <= 4'd0;
            sp_w_tiles <= 4'd0;
            sp_h_tiles <= 4'd0;
            tile_x_cnt <= 4'd0;
            tile_y_cnt <= 4'd0;
            px_x       <= 4'd0;
            px_y       <= 4'd0;
        end else begin
            case (sp_state)
                S_IDLE: begin
                    if (sprdma_trigger) begin
                        sp_state  <= S_CLEAR;
                        clear_idx <= 16'd0;
                    end
                end

                S_CLEAR: begin
                    spr_fb[clear_idx] <= 16'h0000;
                    if (clear_idx == 16'(FB_SZ-1)) begin
                        sp_state   <= S_READ;
                        sprite_idx <= 8'd0;
                    end else begin
                        clear_idx <= clear_idx + 16'd1;
                    end
                end

                S_READ: begin
                    // Latch all attrs this cycle
                    sp_x       <= sp_word4[8:0];
                    sp_y       <= sp_word6[8:0];
                    sp_code    <= sp_word3;
                    sp_pal     <= sp_word7[3:0];
                    sp_w_tiles <= sp_word1[3:0];
                    sp_h_tiles <= sp_word1[7:4];
                    tile_x_cnt <= 4'd0;
                    tile_y_cnt <= 4'd0;
                    px_x       <= 4'd0;
                    px_y       <= 4'd0;

                    if (!sp_enabled) begin
                        sp_state <= S_NEXT;
                    end else begin
                        sp_state <= S_DRAW;
                    end
                end

                S_DRAW: begin
                    // Write pixel if in active area and non-transparent
                    if (in_bounds && cur_opaque) begin
                        spr_fb[fb_addr] <= {1'b1, 5'b0,
                                            2'b01, sp_pal, cur_pixel};
                        //                    opaque,                                palette_idx = $100 + pal*16 + pixel
                    end

                    // Advance pixel counter with 4-deep nesting
                    if (px_x != 4'd15) begin
                        px_x <= px_x + 4'd1;
                    end else begin
                        px_x <= 4'd0;
                        if (px_y != 4'd15) begin
                            px_y <= px_y + 4'd1;
                        end else begin
                            px_y <= 4'd0;
                            if (tile_x_cnt != sp_w_tiles) begin
                                tile_x_cnt <= tile_x_cnt + 4'd1;
                            end else begin
                                tile_x_cnt <= 4'd0;
                                if (tile_y_cnt != sp_h_tiles) begin
                                    tile_y_cnt <= tile_y_cnt + 4'd1;
                                end else begin
                                    sp_state <= S_NEXT;
                                end
                            end
                        end
                    end
                end

                S_NEXT: begin
                    if (sprite_idx == 8'd255) begin
                        sp_state <= S_IDLE;
                    end else begin
                        sprite_idx <= sprite_idx + 8'd1;
                        sp_state   <= S_READ;
                    end
                end

                default: sp_state <= S_IDLE;
            endcase
        end
    end

    // -----------------------------------------------------------------
    // Mixer: BG (opaque base) < sprites (when opaque) < TX (when pen != 15)
    // -----------------------------------------------------------------
    wire [11:0] screen_x = {3'b0, hpos_w} - 12'd92;
    wire [11:0] screen_y = {3'b0, vpos_w} - 12'd16;
    wire        in_active = (screen_x < 12'(FB_W)) && (screen_y < 12'(FB_H));
    wire [15:0] spr_fb_addr = screen_y[7:0] * 16'(FB_W) + {8'd0, screen_x[7:0]};
    wire [15:0] spr_px = in_active ? spr_fb[spr_fb_addr] : 16'h0000;
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

    assign vga_hsync = hsync_w;
    assign vga_vsync = vsync_w;
    assign vga_de    = active;

    assign cpu_addr      = eab;
    assign cpu_as_n      = ASn;
    assign cpu_uds_n_o   = UDSn;
    assign cpu_lds_n_o   = LDSn;
    assign cpu_rw        = eRWn;
    assign cpu_din       = iEdb;
    assign cpu_dout      = oEdb;
    assign cpu_fc        = FC;
    assign irq_ipl       = ipl;
    assign irq_ack_pulse = irq_ack;
    assign vpos_out      = vpos_w;
    assign hpos_out      = hpos_w;

endmodule

`default_nettype wire
