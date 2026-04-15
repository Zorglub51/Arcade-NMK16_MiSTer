// Trivial testbench to verify rtl/sdram.sv compiles under Verilator.
// Not a functional test — just a lint / elaboration check.

`default_nettype none

module sdram_lint_tb;

    logic        clk = 0;
    logic        rst = 1;

    logic        SDRAM_CKE, SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE;
    logic [12:0] SDRAM_A;
    logic [1:0]  SDRAM_BA;
    logic        SDRAM_DQML, SDRAM_DQMH;
    wire  [15:0] SDRAM_DQ;

    logic        wr_req = 0, bg_req = 0, tx_req = 0, spr_req = 0;
    logic [23:0] wr_addr = 0, bg_addr = 0, tx_addr = 0, spr_addr = 0;
    logic [15:0] wr_data = 0;
    logic [1:0]  wr_be = 0;
    logic        wr_ack, bg_ack, tx_ack, spr_ack;
    logic [15:0] bg_data, tx_data, spr_data;
    logic        bg_valid, tx_valid, spr_valid;

    sdram u_sdram (
        .clk(clk), .rst(rst),
        .SDRAM_CKE(SDRAM_CKE), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS),
        .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE),
        .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
        .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_DQ(SDRAM_DQ),
        .wr_req(wr_req), .wr_ack(wr_ack), .wr_addr(wr_addr),
        .wr_data(wr_data), .wr_be(wr_be),
        .bg_req(bg_req), .bg_ack(bg_ack), .bg_addr(bg_addr),
        .bg_data(bg_data), .bg_valid(bg_valid),
        .tx_req(tx_req), .tx_ack(tx_ack), .tx_addr(tx_addr),
        .tx_data(tx_data), .tx_valid(tx_valid),
        .spr_req(spr_req), .spr_ack(spr_ack), .spr_addr(spr_addr),
        .spr_data(spr_data), .spr_valid(spr_valid)
    );

    // No pull-up; leave DQ floating to Z when not driven.
    assign SDRAM_DQ = 16'hZZZZ;

endmodule
