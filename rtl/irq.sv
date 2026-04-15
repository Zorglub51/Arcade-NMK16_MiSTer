// NMK16 — IRQ + video timing generator (NMK902 + 82S135 V-PROM equivalent)
// See docs/architecture.md and hardware reference §A.4 + §C.1.
//
// Phase 2 implementation: hardcoded hachamf event schedule rather than the
// real V-PROM lookup. Same observable behaviour for this game.
//
// Screen timing (low-res, 6 MHz pixel clock):
//   384 px/line, 278 lines/frame  -> 56.2 Hz
//   Active: x=92..347 (256 px), y=16..239 (224 lines)
//
// Hachamf interrupts (per docs/hachamf_hardware_reference.md §A.4):
//   IRQ2 @ line 16   (VBIN)            -> autovector $68
//   IRQ4 @ line 240  (VBOUT)           -> autovector $70
//   IRQ1 @ lines 68 and 196 (mid-screen)-> autovector $64
//   SPRDMA pulse at line 242 (one-cycle strobe to sprite engine)
//
// IRQs are level-asserted via IPL[2:0] and stay latched until the CPU runs
// an IACK cycle (FC=111) at which point they auto-clear (HOLD_LINE in MAME).

`default_nettype none

module irq (
    input  wire        clk_sys,
    input  wire        rst,
    input  wire        ce_pix,         // 6 MHz pixel enable

    // Counters out
    output reg  [8:0]  hpos,           // 0..383
    output reg  [8:0]  vpos,           // 0..277

    // Video timing strobes
    output wire        hsync,          // active-low (pixels 0..31)
    output wire        vsync,          // active-low (lines 0..1)
    output wire        hblank,
    output wire        vblank,

    // To 68000
    output reg  [2:0]  ipl,            // active-high; 0=none, 1/2/4 used
    input  wire        irq_ack,        // 1-cycle pulse from CPU on IACK

    // To sprites.sv (one-cycle pulse near line 242)
    output reg         sprdma_trigger
);

    // ---------------- Counters ----------------
    localparam int H_TOTAL    = 384;
    localparam int V_TOTAL    = 278;
    localparam int H_SYNC_END = 32;
    localparam int H_ACT_BEG  = 92;
    localparam int H_ACT_END  = 348;
    localparam int V_SYNC_END = 2;
    localparam int V_ACT_BEG  = 16;
    localparam int V_ACT_END  = 240;

    always @(posedge clk_sys) begin
        if (rst) begin
            hpos <= 9'd0;
            vpos <= 9'd0;
        end else if (ce_pix) begin
            if (hpos == H_TOTAL - 1) begin
                hpos <= 9'd0;
                vpos <= (vpos == V_TOTAL - 1) ? 9'd0 : (vpos + 9'd1);
            end else begin
                hpos <= hpos + 9'd1;
            end
        end
    end

    assign hsync  = ~(hpos < H_SYNC_END);
    assign vsync  = ~(vpos < V_SYNC_END);
    assign hblank = ~((hpos >= H_ACT_BEG) && (hpos < H_ACT_END));
    assign vblank = ~((vpos >= V_ACT_BEG) && (vpos < V_ACT_END));

    // ---------------- Event scheduler ----------------
    //
    // Events fire on hpos==0 (line start) for the listed vpos. We level-latch
    // a per-IRQ "pending" register and present the highest-pending IPL on the
    // bus. CPU IACK (irq_ack pulse) clears the level it acknowledged.

    reg pend_irq1, pend_irq2, pend_irq4;

    wire line_start_pulse = ce_pix && (hpos == 0);

    always @(posedge clk_sys) begin
        if (rst) begin
            pend_irq1      <= 1'b0;
            pend_irq2      <= 1'b0;
            pend_irq4      <= 1'b0;
            sprdma_trigger <= 1'b0;
        end else begin
            sprdma_trigger <= 1'b0;          // default: low

            if (line_start_pulse) begin
                if (vpos == 9'd16)                      pend_irq2 <= 1'b1; // VBIN
                if (vpos == 9'd240)                     pend_irq4 <= 1'b1; // VBOUT
                if (vpos == 9'd68 || vpos == 9'd196)    pend_irq1 <= 1'b1; // mid-screen
                if (vpos == 9'd242)                     sprdma_trigger <= 1'b1;
            end

            // CPU acked an IRQ — clear the highest-priority pending bit
            // (68000 always acks the highest level it sees).
            if (irq_ack) begin
                if      (pend_irq4) pend_irq4 <= 1'b0;
                else if (pend_irq2) pend_irq2 <= 1'b0;
                else if (pend_irq1) pend_irq1 <= 1'b0;
            end
        end
    end

    // Present the highest pending level
    always @(*) begin
        if      (pend_irq4) ipl = 3'd4;
        else if (pend_irq2) ipl = 3'd2;
        else if (pend_irq1) ipl = 3'd1;
        else                ipl = 3'd0;
    end

endmodule

`default_nettype wire
