// Minimal SDRAM controller for MiSTer DE10-Nano SDRAM module.
// Target chip: 32M×16 at 96 MHz (CL=2 / 3 safe margin).
// Assumes 13-row / 9-col / 2-bank organization (64 MiB address space).
// Open-row policy: rows stay activated until a different row / same bank is needed.
//
// Ports:
//   - One write port (priority LOWEST; only used during ioctl download, idle otherwise).
//   - Three read ports (BG > TX > SPR priority during active, any during VBLANK).
//   - Static priority arbiter; no reordering, no burst.
//   - Latency: ~6–8 master cycles from request accepted to data valid.
//
// Refresh: forced auto-refresh every REFRESH_CYCLES master clocks. During
// refresh the arbiter rejects new requests.
//
// This is a minimal functional controller — it will NOT be the tightest
// implementation possible, but it is small, readable, and straightforward
// to debug. The sim model (testbench/sdram_model.sv) matches these
// timings.

`default_nettype none

module sdram #(
    parameter int CLK_MHZ      = 96,        // master clock
    parameter int ROW_BITS     = 13,
    parameter int COL_BITS     = 9,
    parameter int CAS_LATENCY  = 2,         // CL=2
    parameter int REFRESH_US   = 15         // refresh interval in microseconds
) (
    input  wire        clk,
    input  wire        rst,

    // Chip interface (matches DE10-Nano SDRAM_* pin names)
    output reg         SDRAM_CKE,
    output reg         SDRAM_nCS,
    output reg         SDRAM_nRAS,
    output reg         SDRAM_nCAS,
    output reg         SDRAM_nWE,
    output reg  [12:0] SDRAM_A,
    output reg  [1:0]  SDRAM_BA,
    output reg         SDRAM_DQML,
    output reg         SDRAM_DQMH,
    inout  wire [15:0] SDRAM_DQ,

    // ---- Write port (ioctl downloads) -----------------------------
    input  wire        wr_req,            // pulse to submit one write
    output wire        wr_ack,            // 1-cycle pulse when accepted
    input  wire [23:0] wr_addr,           // byte-addressed (0..16 MiB used)
    input  wire [15:0] wr_data,
    input  wire [1:0]  wr_be,             // byte enables {UB,LB}; 2'b00 = both

    // ---- BG read port ---------------------------------------------
    input  wire        bg_req,
    output wire        bg_ack,
    input  wire [23:0] bg_addr,
    output reg  [15:0] bg_data,
    output reg         bg_valid,          // pulsed when bg_data is fresh

    // ---- TX read port ---------------------------------------------
    input  wire        tx_req,
    output wire        tx_ack,
    input  wire [23:0] tx_addr,
    output reg  [15:0] tx_data,
    output reg         tx_valid,

    // ---- Sprite read port -----------------------------------------
    input  wire        spr_req,
    output wire        spr_ack,
    input  wire [23:0] spr_addr,
    output reg  [15:0] spr_data,
    output reg         spr_valid
);

    localparam [3:0]
        CMD_NOP    = 4'b0111,
        CMD_ACT    = 4'b0011,
        CMD_READ   = 4'b0101,
        CMD_WRITE  = 4'b0100,
        CMD_PRE    = 4'b0010,
        CMD_REFR   = 4'b0001,
        CMD_MRS    = 4'b0000;

    // Compute refresh period in cycles
    localparam int REFRESH_CYCLES = REFRESH_US * CLK_MHZ;

    // Address field extract (byte addr → row/bank/col, 16-bit word at col[8:0], word addr = byte>>1)
    function automatic [ROW_BITS-1:0] row_of(input [23:0] byte_addr);
        begin row_of = byte_addr[23 -: ROW_BITS]; end  // top bits
    endfunction
    function automatic [1:0]          bank_of(input [23:0] byte_addr);
        begin bank_of = byte_addr[23-ROW_BITS -: 2]; end
    endfunction
    function automatic [COL_BITS-1:0] col_of(input [23:0] byte_addr);
        // word address is byte_addr[23:1]; low COL_BITS of that
        begin col_of = byte_addr[COL_BITS:1]; end
    endfunction

    // FSM states
    typedef enum logic [3:0] {
        ST_INIT_WAIT,       // 200 µs power-on wait
        ST_INIT_PRECHARGE,
        ST_INIT_REFRESH1,
        ST_INIT_REFRESH2,
        ST_INIT_MRS,
        ST_IDLE,
        ST_ACT,
        ST_READ_CMD,
        ST_READ_WAIT,
        ST_WRITE_CMD,
        ST_PRE,
        ST_REFR
    } state_t;

    state_t state;
    reg [19:0] init_cnt;
    reg [4:0]  step_cnt;          // steps within a state
    reg [15:0] refresh_timer;

    // Pending request registration (captures the granted req at arb time)
    reg        have_req;
    reg        req_is_write;
    reg [1:0]  req_is_read_src;   // 00=BG, 01=TX, 10=SPR (when !req_is_write)
    reg [23:0] req_addr;
    reg [15:0] req_wdata;
    reg [1:0]  req_wbe;

    // Output latency-tracking pipeline
    reg        rd_in_flight;
    reg [1:0]  rd_src_in_flight;  // same encoding as req_is_read_src
    reg [2:0]  rd_cas_cnt;

    // Tri-state for DQ (drive only on writes)
    reg        dq_drive;
    reg [15:0] dq_out;
    assign SDRAM_DQ = dq_drive ? dq_out : 16'hZZZZ;

    // Ack outputs (pulsed one cycle when arb accepts)
    reg wr_ack_r, bg_ack_r, tx_ack_r, spr_ack_r;
    assign wr_ack  = wr_ack_r;
    assign bg_ack  = bg_ack_r;
    assign tx_ack  = tx_ack_r;
    assign spr_ack = spr_ack_r;

    // Convenience: drive command pins
    task automatic drive_cmd(input [3:0] c);
        {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= c;
    endtask

    // Main FSM
    always @(posedge clk) begin
        // Defaults every cycle
        drive_cmd(CMD_NOP);
        SDRAM_A    <= '0;
        SDRAM_BA   <= '0;
        SDRAM_DQML <= 1'b0;
        SDRAM_DQMH <= 1'b0;
        dq_drive   <= 1'b0;
        dq_out     <= '0;
        wr_ack_r   <= 1'b0;
        bg_ack_r   <= 1'b0;
        tx_ack_r   <= 1'b0;
        spr_ack_r  <= 1'b0;
        bg_valid   <= 1'b0;
        tx_valid   <= 1'b0;
        spr_valid  <= 1'b0;

        if (rst) begin
            state         <= ST_INIT_WAIT;
            init_cnt      <= 20'd0;
            step_cnt      <= 5'd0;
            refresh_timer <= 16'd0;
            have_req      <= 1'b0;
            rd_in_flight  <= 1'b0;
            SDRAM_CKE     <= 1'b0;
            rd_cas_cnt    <= 3'd0;
        end else begin
            refresh_timer <= refresh_timer + 16'd1;

            // Latency counter: when a READ was issued, count CAS cycles then capture data
            if (rd_in_flight) begin
                if (rd_cas_cnt == CAS_LATENCY[2:0]) begin
                    case (rd_src_in_flight)
                        2'b00: begin bg_data  <= SDRAM_DQ; bg_valid  <= 1'b1; end
                        2'b01: begin tx_data  <= SDRAM_DQ; tx_valid  <= 1'b1; end
                        2'b10: begin spr_data <= SDRAM_DQ; spr_valid <= 1'b1; end
                        default:;
                    endcase
                    rd_in_flight <= 1'b0;
                end else begin
                    rd_cas_cnt <= rd_cas_cnt + 3'd1;
                end
            end

            case (state)
                // ---- Init: 200 µs wait, then precharge-all, refresh×2, MRS ----
                ST_INIT_WAIT: begin
                    SDRAM_CKE <= 1'b1;
                    if (init_cnt == 20'(200 * CLK_MHZ)) begin
                        state <= ST_INIT_PRECHARGE;
                        init_cnt <= 20'd0;
                    end else
                        init_cnt <= init_cnt + 20'd1;
                end
                ST_INIT_PRECHARGE: begin
                    drive_cmd(CMD_PRE);
                    SDRAM_A[10] <= 1'b1;        // A10=1 → precharge all banks
                    state       <= ST_INIT_REFRESH1;
                    step_cnt    <= 5'd0;
                end
                ST_INIT_REFRESH1: begin
                    if (step_cnt == 5'd0) drive_cmd(CMD_REFR);
                    if (step_cnt == 5'd15) begin
                        state    <= ST_INIT_REFRESH2;
                        step_cnt <= 5'd0;
                    end else
                        step_cnt <= step_cnt + 5'd1;
                end
                ST_INIT_REFRESH2: begin
                    if (step_cnt == 5'd0) drive_cmd(CMD_REFR);
                    if (step_cnt == 5'd15) begin
                        state    <= ST_INIT_MRS;
                        step_cnt <= 5'd0;
                    end else
                        step_cnt <= step_cnt + 5'd1;
                end
                ST_INIT_MRS: begin
                    drive_cmd(CMD_MRS);
                    // Mode register: CL=2, BL=1, sequential
                    //   A[2:0]=000 BL=1, A3=0 seq, A[6:4]=010 CL=2, A[11:7]=0
                    SDRAM_A <= 13'b0_0000_0010_0000;
                    state   <= ST_IDLE;
                end

                // ---- Normal operation ----
                ST_IDLE: begin
                    // Arbitrate: refresh > BG > TX > SPR > WR
                    if (refresh_timer >= 16'(REFRESH_CYCLES)) begin
                        state         <= ST_REFR;
                        refresh_timer <= 16'd0;
                        step_cnt      <= 5'd0;
                    end else if (bg_req && !rd_in_flight) begin
                        have_req         <= 1'b1;
                        req_is_write     <= 1'b0;
                        req_is_read_src  <= 2'b00;
                        req_addr         <= bg_addr;
                        bg_ack_r         <= 1'b1;
                        state            <= ST_ACT;
                    end else if (tx_req && !rd_in_flight) begin
                        have_req         <= 1'b1;
                        req_is_write     <= 1'b0;
                        req_is_read_src  <= 2'b01;
                        req_addr         <= tx_addr;
                        tx_ack_r         <= 1'b1;
                        state            <= ST_ACT;
                    end else if (spr_req && !rd_in_flight) begin
                        have_req         <= 1'b1;
                        req_is_write     <= 1'b0;
                        req_is_read_src  <= 2'b10;
                        req_addr         <= spr_addr;
                        spr_ack_r        <= 1'b1;
                        state            <= ST_ACT;
                    end else if (wr_req) begin
                        have_req         <= 1'b1;
                        req_is_write     <= 1'b1;
                        req_addr         <= wr_addr;
                        req_wdata        <= wr_data;
                        req_wbe          <= wr_be;
                        wr_ack_r         <= 1'b1;
                        state            <= ST_ACT;
                    end
                end

                ST_ACT: begin
                    drive_cmd(CMD_ACT);
                    SDRAM_BA <= bank_of(req_addr);
                    SDRAM_A  <= row_of(req_addr);
                    state    <= req_is_write ? ST_WRITE_CMD : ST_READ_CMD;
                    step_cnt <= 5'd0;
                end

                ST_READ_CMD: begin
                    // tRCD typ 2 cycles @96MHz; insert 1 NOP then issue READ
                    if (step_cnt < 5'd1) begin
                        step_cnt <= step_cnt + 5'd1;
                    end else begin
                        drive_cmd(CMD_READ);
                        SDRAM_BA   <= bank_of(req_addr);
                        // A[12:10] = 001 (only A10=1 auto-precharge), A[9]=0, A[8:0]=col
                        SDRAM_A    <= {3'b001, 1'b0, col_of(req_addr)};  // 3+1+9 = 13 bits
                        SDRAM_DQML <= 1'b0;
                        SDRAM_DQMH <= 1'b0;
                        // start latency counter for the in-flight read
                        rd_in_flight     <= 1'b1;
                        rd_src_in_flight <= req_is_read_src;
                        rd_cas_cnt       <= 3'd0;
                        state            <= ST_IDLE;
                        have_req         <= 1'b0;
                    end
                end

                ST_WRITE_CMD: begin
                    if (step_cnt < 5'd1) begin
                        step_cnt <= step_cnt + 5'd1;
                    end else begin
                        drive_cmd(CMD_WRITE);
                        SDRAM_BA   <= bank_of(req_addr);
                        SDRAM_A    <= {3'b001, 1'b0, col_of(req_addr)}; // auto-precharge
                        SDRAM_DQML <= req_wbe[0];
                        SDRAM_DQMH <= req_wbe[1];
                        dq_drive   <= 1'b1;
                        dq_out     <= req_wdata;
                        state      <= ST_IDLE;
                        have_req   <= 1'b0;
                    end
                end

                ST_REFR: begin
                    if (step_cnt == 5'd0) drive_cmd(CMD_REFR);
                    if (step_cnt == 5'd10) begin
                        state <= ST_IDLE;
                    end else
                        step_cnt <= step_cnt + 5'd1;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
