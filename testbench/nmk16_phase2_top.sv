// NMK_Core Phase 2 testbench top.
// Goal: get the hachamfb 68000 to leave the boot DBF wait-loop by serving real
// IRQs at hachamf scanlines, and to write meaningfully into video VRAM
// + scroll/control regs (which we latch silently — Phase 3 will display them).
//
// Memory map enabled this phase:
//   $000000-$03FFFF  Program ROM        (RO)
//   $080000.W        IN0  read          (top byte = inputs)
//   $080002.W        IN1  read          (16-bit P1+P2)
//   $080008.W        DSW1 read          (low byte)
//   $08000A.W        DSW2 read          (low byte)
//   $08000F.B        NMK004 -> main     (returns 0 for now)
//   $080015.B        flipscreen         (latched)
//   $080016.W        NMK004 NMI         (latched, no reset action)
//   $080019.B        BG tilebank        (latched)
//   $08001F.B        main -> NMK004     (latched)
//   $08C001/3/5/7.B  scroll regs        (latched)
//   $088000-$0887FF  palette RAM        (R/W,  1 KW)
//   $090000-$093FFF  BG VRAM            (R/W,  8 KW)
//   $09C000-$09C7FF  TX VRAM            (R/W,  1 KW)
//   $0F0000-$0FFFFF  Work RAM           (R/W, 32 KW)
//   anything else    return $FFFF, ignore writes
//
// Bus protocol:
//   DTACKn=0 every cycle EXCEPT during IACK; VPAn=0 during IACK so the
//   68000 auto-vectors. irq_ack pulse clears the highest pending level.

`default_nettype none

module nmk16_phase2_top (
    input  wire        clk,
    input  wire        rst,

    // Per-frame stimulus
    input  wire [7:0]  in0_keys,        // active-low: see docs/memmap.md IN0
    input  wire [15:0] in1_keys,        // active-low: P1+P2 sticks/buttons
    input  wire [7:0]  dsw1,            // raw byte
    input  wire [7:0]  dsw2,

    // Trace probes
    output wire [23:1] cpu_addr,
    output wire [15:0] cpu_dout,
    output wire        cpu_as_n,
    output wire        cpu_uds_n,
    output wire        cpu_lds_n,
    output wire        cpu_rw,
    output wire [2:0]  cpu_fc,
    output wire [15:0] cpu_din,
    output wire        irq_ack_pulse,
    output wire [2:0]  irq_ipl,
    output wire [8:0]  vpos_out,
    output wire [8:0]  hpos_out
);

    // -----------------------------------------------------------------
    // Clock enables
    //   enPhi1/enPhi2 : alternate every cycle (CPU bus cycle = 8 master clk)
    //   ce_pix        : every PIX_DIV master clk; lets us trade real-time
    //                   accuracy for sim speed by giving the CPU many more
    //                   bus cycles per simulated scanline.
    // -----------------------------------------------------------------
    reg phi_toggle;
    always @(posedge clk) begin
        if (rst) phi_toggle <= 1'b0;
        else     phi_toggle <= ~phi_toggle;
    end
    wire enPhi1 = ~phi_toggle;
    wire enPhi2 =  phi_toggle;

    localparam int PIX_DIV = 16;          // raise to skim past long boot delays
    reg [7:0] pix_cnt;
    always @(posedge clk) begin
        if (rst)                    pix_cnt <= 8'd0;
        else if (pix_cnt == PIX_DIV-1) pix_cnt <= 8'd0;
        else                        pix_cnt <= pix_cnt + 8'd1;
    end
    wire ce_pix = (pix_cnt == 8'd0);

    // -----------------------------------------------------------------
    // IRQ generator
    // -----------------------------------------------------------------
    wire [2:0] ipl;
    wire       sprdma_trig_unused;
    wire       hsync_u, vsync_u, hblank_u, vblank_u;
    wire [8:0] hpos_w, vpos_w;
    reg        irq_ack;

    irq u_irq (
        .clk_sys        (clk),
        .rst            (rst),
        .ce_pix         (ce_pix),
        .hpos           (hpos_w),
        .vpos           (vpos_w),
        .hsync          (hsync_u),
        .vsync          (vsync_u),
        .hblank         (hblank_u),
        .vblank         (vblank_u),
        .ipl            (ipl),
        .irq_ack        (irq_ack),
        .sprdma_trigger (sprdma_trig_unused)
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

    // IACK detection: FC=111 + ASn asserted
    wire is_iack = (FC == 3'b111) && !ASn;

    // VPA only during IACK; DTACK always except IACK
    wire VPAn   = ~is_iack;
    wire DTACKn =  is_iack;
    wire BERRn  = 1'b1;
    wire BRn    = 1'b1;
    wire BGACKn = 1'b1;
    wire HALTn  = 1'b1;

    // Active-low IPL inputs
    wire IPL0n = ~ipl[0];
    wire IPL1n = ~ipl[1];
    wire IPL2n = ~ipl[2];

    fx68k u_cpu (
        .clk        (clk),
        .HALTn      (HALTn),
        .extReset   (rst),
        .pwrUp      (rst),
        .enPhi1     (enPhi1),
        .enPhi2     (enPhi2),
        .eRWn       (eRWn),
        .ASn        (ASn),
        .LDSn       (LDSn),
        .UDSn       (UDSn),
        .E          (E_u),
        .VMAn       (VMAn_u),
        .FC0        (FC[0]),
        .FC1        (FC[1]),
        .FC2        (FC[2]),
        .BGn        (BGn_u),
        .oRESETn    (oRESETn_u),
        .oHALTEDn   (oHALTEDn_u),
        .DTACKn     (DTACKn),
        .VPAn       (VPAn),
        .BERRn      (BERRn),
        .BRn        (BRn),
        .BGACKn     (BGACKn),
        .IPL0n      (IPL0n),
        .IPL1n      (IPL1n),
        .IPL2n      (IPL2n),
        .iEdb       (iEdb),
        .oEdb       (oEdb),
        .eab        (eab)
    );

    // Pulse irq_ack on falling edge of ASn during IACK.
    reg as_d;
    always @(posedge clk) as_d <= ASn;
    wire as_falling = as_d & ~ASn;
    always @(posedge clk) begin
        if (rst) irq_ack <= 1'b0;
        else     irq_ack <= as_falling && is_iack;
    end

    // -----------------------------------------------------------------
    // ROM
    // -----------------------------------------------------------------
    `ifndef ROM_PATH
        `define ROM_PATH "../roms/hachamfb_prog.hex"
    `endif

    reg [15:0] rom [0:131071];
    initial $readmemh(`ROM_PATH, rom);

    // -----------------------------------------------------------------
    // RAMs (CPU-only access this phase)
    // -----------------------------------------------------------------
    reg [15:0] wram [0:32767];        // $0F0000-$0FFFFF
    reg [15:0] bgvram [0:8191];       // $090000-$093FFF
    reg [15:0] txvram [0:1023];       // $09C000-$09C7FF
    reg [15:0] palram [0:1023];       // $088000-$0887FF
    integer i;
    initial begin
        for (i = 0; i < 32768; i = i + 1) wram[i]   = 16'h0000;
        for (i = 0; i < 8192;  i = i + 1) bgvram[i] = 16'h0000;
        for (i = 0; i < 1024;  i = i + 1) txvram[i] = 16'h0000;
        for (i = 0; i < 1024;  i = i + 1) palram[i] = 16'h0000;
    end

    // -----------------------------------------------------------------
    // Region selects
    // -----------------------------------------------------------------
    wire is_rom    = (eab[23:18] == 6'b000000);
    wire is_io_lo  = (eab[23:16] == 8'h08) && (eab[15:8] == 8'h00); // $080000-$0800FF
    wire is_pal    = (eab[23:11] == 13'b00001000_1000_0); // $088000-$0887FF
    wire is_scroll = (eab[23:8]  == 16'h08C0);            // $08C000-$08C0FF (regs at $08C001/3/5/7)
    wire is_bgvram = (eab[23:14] == 10'b0000_1001_00);    // $090000-$093FFF
    wire is_txvram = (eab[23:11] == 13'b00001001_1100_0); // $09C000-$09C7FF
    wire is_wram   = (eab[23:16] == 8'h0F);

    wire [14:0] wram_widx   = eab[15:1];
    wire [12:0] bgvram_widx = eab[13:1];
    wire [9:0]  txvram_widx = eab[10:1];
    wire [9:0]  palram_widx = eab[10:1];
    wire [16:0] rom_widx    = eab[17:1];

    // -----------------------------------------------------------------
    // I/O register file (control side)
    // -----------------------------------------------------------------
    reg        flipscreen;
    reg [7:0]  bgbank;
    reg [7:0]  scroll_xh, scroll_xl, scroll_yh, scroll_yl;
    reg [7:0]  nmk004_to_snd;
    reg        nmk004_nmi;

    // Combined byte-write strobe: write while ASn=0, eRWn=0, and the
    // appropriate data strobe is asserted. We latch on the *rising* edge of
    // the strobe (= end of bus cycle) so the data is guaranteed valid.
    reg uds_d, lds_d;
    always @(posedge clk) begin
        uds_d <= UDSn;
        lds_d <= LDSn;
    end
    wire uds_rising = ~uds_d &  UDSn;     // UDSn went 0 -> 1
    wire lds_rising = ~lds_d &  LDSn;     // LDSn went 0 -> 1
    wire write_now  = !eRWn && (uds_rising || lds_rising);

    // I/O writes (low-byte writes use LDS strobe on word writes)
    always @(posedge clk) begin
        if (rst) begin
            flipscreen    <= 1'b0;
            bgbank        <= 8'h00;
            scroll_xh     <= 8'h00; scroll_xl <= 8'h00;
            scroll_yh     <= 8'h00; scroll_yl <= 8'h00;
            nmk004_to_snd <= 8'h00;
            nmk004_nmi    <= 1'b0;
        end else if (write_now) begin
            // Convert eab[23:1] back to byte address for clarity
            // (eab is word-addr; full byte address = {eab, 1'b0})
            // I/O regs (odd-byte writes use LDS = !LDSn)
            if (is_io_lo) begin
                case (eab[7:1])
                    7'h0A: if (lds_rising) flipscreen    <= oEdb[0];   // $080015 odd
                    7'h0B: if (lds_rising) nmk004_nmi    <= oEdb[0];   // $080016/17
                    7'h0C: if (lds_rising) bgbank        <= oEdb[7:0]; // $080019 odd
                    7'h0F: if (lds_rising) nmk004_to_snd <= oEdb[7:0]; // $08001F odd
                    default: ;
                endcase
            end
            if (is_scroll) begin
                case (eab[7:1])
                    7'h00: if (lds_rising) scroll_xh <= oEdb[7:0];     // $08C001
                    7'h01: if (lds_rising) scroll_xl <= oEdb[7:0];     // $08C003
                    7'h02: if (lds_rising) scroll_yh <= oEdb[7:0];     // $08C005
                    7'h03: if (lds_rising) scroll_yl <= oEdb[7:0];     // $08C007
                    default: ;
                endcase
            end
        end
    end

    // VRAM / palette / workram writes — latch on rising edge of the strobe
    // (= end of bus cycle, data definitely valid).
    always @(posedge clk) begin
        if (!rst && !eRWn) begin
            if (is_wram) begin
                if (uds_rising) wram[wram_widx][15:8] <= oEdb[15:8];
                if (lds_rising) wram[wram_widx][ 7:0] <= oEdb[ 7:0];
            end
            if (is_bgvram) begin
                if (uds_rising) bgvram[bgvram_widx][15:8] <= oEdb[15:8];
                if (lds_rising) bgvram[bgvram_widx][ 7:0] <= oEdb[ 7:0];
            end
            if (is_txvram) begin
                if (uds_rising) txvram[txvram_widx][15:8] <= oEdb[15:8];
                if (lds_rising) txvram[txvram_widx][ 7:0] <= oEdb[ 7:0];
            end
            if (is_pal) begin
                if (uds_rising) palram[palram_widx][15:8] <= oEdb[15:8];
                if (lds_rising) palram[palram_widx][ 7:0] <= oEdb[ 7:0];
            end
        end
    end

    // I/O read mux
    reg [15:0] io_rd;
    always @(*) begin
        io_rd = 16'hFFFF;
        if (is_io_lo) begin
            case (eab[7:1])
                7'h00: io_rd = {in0_keys, 8'h00};      // $080000.W: byte 0 = IN0
                7'h01: io_rd = in1_keys;               // $080002.W: 16-bit IN1
                7'h04: io_rd = {8'h00, dsw1};          // $080008.W low byte = DSW1
                7'h05: io_rd = {8'h00, dsw2};          // $08000A.W low byte = DSW2
                7'h07: io_rd = 16'h0000;               // $08000F.B NMK004 -> main (idle)
                default: io_rd = 16'hFFFF;
            endcase
        end
    end

    // -----------------------------------------------------------------
    // CPU read mux
    // -----------------------------------------------------------------
    assign iEdb = is_rom    ? rom[rom_widx]
                : is_wram   ? wram[wram_widx]
                : is_bgvram ? bgvram[bgvram_widx]
                : is_txvram ? txvram[txvram_widx]
                : is_pal    ? palram[palram_widx]
                : is_io_lo  ? io_rd
                :             16'hFFFF;

    // -----------------------------------------------------------------
    // Trace probes
    // -----------------------------------------------------------------
    assign cpu_addr      = eab;
    assign cpu_dout      = oEdb;
    assign cpu_as_n      = ASn;
    assign cpu_uds_n     = UDSn;
    assign cpu_lds_n     = LDSn;
    assign cpu_rw        = eRWn;
    assign cpu_fc        = FC;
    assign cpu_din       = iEdb;
    assign irq_ack_pulse = irq_ack;
    assign irq_ipl       = ipl;
    assign vpos_out      = vpos_w;
    assign hpos_out      = hpos_w;

endmodule

`default_nettype wire
