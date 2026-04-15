// NMK_Core Phase 1 testbench top.
// Goal: get the hachamfb 68000 program fetching and executing instructions
// against ROM + workram. Everything else (I/O, video, sound) returns $FFFF
// and silently absorbs writes; IRQs are tied off.
//
// Memory map for this stub:
//   $000000-$03FFFF  Program ROM       (128 Ki words, init from hachamfb_prog.hex)
//   $0F0000-$0FFFFF  Work RAM          ( 32 Ki words, zero-initialized)
//   everything else  bus-bridge stub   (returns $FFFF on read, ignores writes)
//
// We DTACK every cycle (no waitstates) and never assert BERR — the goal is
// to observe what the CPU does, not enforce real-bus behaviour. Phase 2 adds
// real DTACK/BERR + IRQ scheduling.

`default_nettype none

module nmk16_phase1_top (
    input  wire        clk,
    input  wire        rst,             // synchronous, active-high

    // Trace probes (just for the C++ harness to inspect)
    output wire [23:1] cpu_addr,
    output wire [15:0] cpu_dout,
    output wire        cpu_as_n,
    output wire        cpu_uds_n,
    output wire        cpu_lds_n,
    output wire        cpu_rw,          // 1 = read, 0 = write (eRWn)
    output wire [2:0]  cpu_fc,
    output wire        cpu_reset_out,   // active-low oRESETn
    output wire        cpu_halted_out,  // active-low oHALTEDn

    // Mirrored bus data the CPU sees this cycle
    output wire [15:0] cpu_din
);

    // -----------------------------------------------------------------
    // 68000 clock phase generator: enPhi1 / enPhi2 strobe alternately
    // -----------------------------------------------------------------
    reg phi_toggle;
    always @(posedge clk) begin
        if (rst) phi_toggle <= 1'b0;
        else     phi_toggle <= ~phi_toggle;
    end
    wire enPhi1 = ~phi_toggle;
    wire enPhi2 =  phi_toggle;

    // -----------------------------------------------------------------
    // CPU instance
    // -----------------------------------------------------------------
    wire        ASn, UDSn, LDSn, eRWn;
    wire        E_unused, VMAn_unused;
    wire [2:0]  FC;
    wire        BGn_unused, oRESETn, oHALTEDn;
    wire [15:0] iEdb, oEdb;
    wire [23:1] eab;

    // Tied-off bus inputs
    wire DTACKn = 1'b0;            // permissive: always ack
    wire VPAn   = 1'b1;            // no autovector / VPA cycles
    wire BERRn  = 1'b1;            // never assert bus error
    wire BRn    = 1'b1;            // no external bus request
    wire BGACKn = 1'b1;            // no external bus master
    wire IPL0n  = 1'b1;            // no IRQ
    wire IPL1n  = 1'b1;
    wire IPL2n  = 1'b1;
    wire HALTn  = 1'b1;            // run

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
        .E          (E_unused),
        .VMAn       (VMAn_unused),
        .FC0        (FC[0]),
        .FC1        (FC[1]),
        .FC2        (FC[2]),
        .BGn        (BGn_unused),
        .oRESETn    (oRESETn),
        .oHALTEDn   (oHALTEDn),
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

    // -----------------------------------------------------------------
    // ROM: 128 Ki words of program at $000000-$03FFFF
    // -----------------------------------------------------------------
    // ROM_PATH passed via Verilator -DROM_PATH=...
    `ifndef ROM_PATH
        `define ROM_PATH "../roms/hachamfb_prog.hex"
    `endif

    reg [15:0] rom [0:131071];
    initial begin
        $readmemh(`ROM_PATH, rom);
    end
    wire [16:0] rom_widx = eab[17:1];     // 17-bit word index (covers $00000-$3FFFF)
    wire [15:0] rom_dout = rom[rom_widx];

    // -----------------------------------------------------------------
    // Workram: 32 Ki words at $0F0000-$0FFFFF
    // -----------------------------------------------------------------
    reg [15:0] wram [0:32767];
    integer i;
    initial begin
        for (i = 0; i < 32768; i = i + 1) wram[i] = 16'h0000;
    end
    wire [14:0] wram_widx = eab[15:1];
    wire [15:0] wram_dout = wram[wram_widx];

    // Region selects (eab[23:18])
    wire is_rom  = (eab[23:18] == 6'b000000);                      // $000000-$03FFFF
    wire is_wram = (eab[23:16] == 8'h0F);                          // $0F0000-$0FFFFF

    // Word write strobes (write happens when ASn=0, !eRWn, on the appropriate phase)
    // Simple model: write on falling edge of ASn (= when bus cycle starts AS=0 + rw=0).
    // Use a registered wstrobe to avoid combinational glitches.
    reg as_d;
    always @(posedge clk) as_d <= ASn;
    wire as_falling = as_d & ~ASn;        // 1 cycle pulse when ASn went low

    always @(posedge clk) begin
        if (!rst && as_falling && !eRWn && is_wram) begin
            if (!UDSn) wram[wram_widx][15:8] <= oEdb[15:8];
            if (!LDSn) wram[wram_widx][ 7:0] <= oEdb[ 7:0];
        end
    end

    // -----------------------------------------------------------------
    // Read mux to CPU
    // -----------------------------------------------------------------
    assign iEdb = is_rom  ? rom_dout
                : is_wram ? wram_dout
                :           16'hFFFF;

    // -----------------------------------------------------------------
    // Trace probes out
    // -----------------------------------------------------------------
    assign cpu_addr        = eab;
    assign cpu_dout        = oEdb;
    assign cpu_as_n        = ASn;
    assign cpu_uds_n       = UDSn;
    assign cpu_lds_n       = LDSn;
    assign cpu_rw          = eRWn;
    assign cpu_fc          = FC;
    assign cpu_reset_out   = oRESETn;
    assign cpu_halted_out  = oHALTEDn;
    assign cpu_din         = iEdb;

endmodule

`default_nettype wire
