// NMK16 test pattern — 8 vertical color bars at native NMK16 timing.
// Used in Phase 0 of docs/roadmap.md to validate the Verilator+SDL toolchain
// on macOS before any real RTL is written.
//
// Timing matches MAME's set_screen_lowres for the NMK16 board:
//   pixel clock 6 MHz (= 12 MHz XTAL / 2)
//   384 px / line (active 92..347 = 256 px)
//   278 lines / frame (active 16..239 = 224 lines)
//   line rate 15.625 kHz, frame rate 56.2 Hz
//   HSYNC active-low at x=0..31
//   VSYNC active-low at lines 0..1 (approximation; real V-PROM table is line-by-line)

`default_nettype none

module nmk16_test_pattern (
    input  logic        clk,           // 6 MHz pixel clock (one tick per pixel)
    input  logic        reset,

    output logic [7:0]  vga_r,
    output logic [7:0]  vga_g,
    output logic [7:0]  vga_b,
    output logic        vga_hsync,     // active low
    output logic        vga_vsync,     // active low
    output logic        vga_de         // 1 inside the 256x224 active area
);

    localparam int H_TOTAL    = 384;
    localparam int H_SYNC_END = 32;
    localparam int H_ACT_BEG  = 92;
    localparam int H_ACT_END  = 348;

    localparam int V_TOTAL    = 278;
    localparam int V_SYNC_END = 2;
    localparam int V_ACT_BEG  = 16;
    localparam int V_ACT_END  = 240;

    logic [8:0] hcount;
    logic [8:0] vcount;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            hcount <= 9'd0;
            vcount <= 9'd0;
        end else begin
            if (hcount == H_TOTAL - 1) begin
                hcount <= 9'd0;
                if (vcount == V_TOTAL - 1)
                    vcount <= 9'd0;
                else
                    vcount <= vcount + 9'd1;
            end else begin
                hcount <= hcount + 9'd1;
            end
        end
    end

    assign vga_hsync = ~(hcount < H_SYNC_END);
    assign vga_vsync = ~(vcount < V_SYNC_END);

    wire h_active = (hcount >= H_ACT_BEG) && (hcount < H_ACT_END);
    wire v_active = (vcount >= V_ACT_BEG) && (vcount < V_ACT_END);
    assign vga_de = h_active && v_active;

    // 8 color bars across 256 active pixels = 32 px per bar
    wire [7:0] x_in_active = hcount[7:0] - H_ACT_BEG[7:0];
    wire [2:0] bar         = x_in_active[7:5];

    always_comb begin
        if (vga_de) begin
            unique case (bar)
                3'd0: {vga_r, vga_g, vga_b} = {8'hFF, 8'hFF, 8'hFF}; // white
                3'd1: {vga_r, vga_g, vga_b} = {8'hFF, 8'hFF, 8'h00}; // yellow
                3'd2: {vga_r, vga_g, vga_b} = {8'h00, 8'hFF, 8'hFF}; // cyan
                3'd3: {vga_r, vga_g, vga_b} = {8'h00, 8'hFF, 8'h00}; // green
                3'd4: {vga_r, vga_g, vga_b} = {8'hFF, 8'h00, 8'hFF}; // magenta
                3'd5: {vga_r, vga_g, vga_b} = {8'hFF, 8'h00, 8'h00}; // red
                3'd6: {vga_r, vga_g, vga_b} = {8'h00, 8'h00, 8'hFF}; // blue
                3'd7: {vga_r, vga_g, vga_b} = {8'h00, 8'h00, 8'h00}; // black
            endcase
        end else begin
            {vga_r, vga_g, vga_b} = 24'h000000;
        end
    end

endmodule

`default_nettype wire
