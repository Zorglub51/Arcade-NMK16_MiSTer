// NMK16 scanline sprite renderer — clean rewrite.
//
// Double-buffered design:
//   - Two 256x16-bit line buffers (A and B), inferred as simple-dual-port
//     M10K blocks. Each buffer has 1 sync read port (mixer) and 1 sync
//     write port (engine). Reads return data 1 clk after addr.
//   - 'front' selects which buffer the mixer reads (0=A, 1=B).
//   - 'back'  selects which buffer the engine writes (0=A, 1=B).
//   - Invariant maintained by the swap logic and reset values:
//     back = ~front. Reset front=0 / back=1 -> mixer reads A while
//     engine writes B from cycle 1.
//   - On each vpos change: flip front, latch (old) front into back,
//     clear the new back, walk sprites for the next visible line.
//
// GFX ROM interface (v2b): request/valid protocol, same as one channel
// of rtl/sdram.sv. The engine issues a read per byte-address, waits
// for `spr_gfx_valid`, and extracts the byte from the 16-bit SDRAM
// word using the address LSB. The line buffer absorbs SDRAM latency
// variance, so the mixer never sees it.
//
// Memory: prior MLAB-async-read inference failed under Quartus 21.1
// with "unsupported read-during-write behavior" — we now use M10K
// sync read with the read result registered, and split the per-pair
// double-write into two single-write states so each buffer has at
// most one write port (clean simple-dual-port inference).

`default_nettype none

module sprite_line (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce_pix,
    input  wire [8:0]  hpos,
    input  wire [8:0]  vpos,

    output reg  [14:0] spr_ram_addr,
    input  wire [15:0] spr_ram_data,

    // GFX ROM read port (req/valid; data is 16-bit word, byte selected by addr[0])
    output reg         spr_gfx_req,
    input  wire        spr_gfx_ack,
    output reg  [23:0] spr_gfx_addr,
    input  wire [15:0] spr_gfx_data,
    input  wire        spr_gfx_valid,

    output wire [9:0]  spr_pal_idx,
    output wire        spr_opaque
);

    // -----------------------------------------------------------------
    // Line buffers. [15]=opaque  [9:0]=palette index.  Bit 15=0 means empty.
    // M10K simple-dual-port: 1R + 1W per array. Read is sync (1 clk).
    // -----------------------------------------------------------------
    (* ramstyle = "M10K, no_rw_check" *) reg [15:0] buf_a [0:255];
    (* ramstyle = "M10K, no_rw_check" *) reg [15:0] buf_b [0:255];

    reg front;
    reg back;

    // Engine write port (1 write per clk; pulsed by FSM).
    reg        wr_en;
    reg [7:0]  wr_addr;
    reg [15:0] wr_data;

    // -----------------------------------------------------------------
    // Mixer — sync read both buffers, then mux registered outputs by
    // registered front. front_q tracks front by 1 clk so the mux pairs
    // the right read result with the right buffer selection.
    // -----------------------------------------------------------------
    wire [7:0] mx = (hpos >= 9'd92 && hpos < 9'd348) ? (hpos[7:0] - 8'd92) : 8'd0;

    reg [15:0] read_a, read_b;
    reg        front_q;

    // Buffer A: write when back==0, read every cycle.
    always @(posedge clk) begin
        if (wr_en && back == 1'b0) buf_a[wr_addr] <= wr_data;
        read_a <= buf_a[mx];
    end
    // Buffer B: write when back==1, read every cycle.
    always @(posedge clk) begin
        if (wr_en && back == 1'b1) buf_b[wr_addr] <= wr_data;
        read_b <= buf_b[mx];
    end
    always @(posedge clk) front_q <= front;

    wire [15:0] front_px = front_q ? read_b : read_a;
    assign spr_opaque  = front_px[15];
    assign spr_pal_idx = front_px[9:0];

    // -----------------------------------------------------------------
    // Engine FSM
    // -----------------------------------------------------------------
    localparam [3:0]
        S_IDLE      = 4'd0,
        S_CLEAR     = 4'd1,
        S_RDEN      = 4'd2,
        S_ATTR      = 4'd3,
        S_CHKY      = 4'd4,
        S_DRAW_REQ  = 4'd5,
        S_DRAW_WAIT = 4'd6,
        S_DRAW_HI   = 4'd7,   // write hi pixel (or skip), advance to LO
        S_DRAW_LO   = 4'd8;   // write lo pixel (or skip), advance pair/tile/sprite

    reg [3:0]  state;
    reg [7:0]  clr_idx;
    reg [7:0]  spr_idx;
    reg [2:0]  attr_step;
    reg [8:0]  sp_x, sp_y;
    reg [15:0] sp_code;
    reg [3:0]  sp_pal, sp_w, sp_h;
    reg [3:0]  tile_x, px_pair;
    reg [8:0]  screen_y;  // screen-space Y for this fill (0..223)
    reg [7:0]  pix_byte;  // captured byte from spr_gfx_data

    // Detect vpos change (1 cycle after irq.sv updates vpos via NBA)
    reg [8:0] prev_vpos;
    wire new_line = (vpos != prev_vpos);

    // Y range check
    wire [15:0] spr_bot = {7'd0, sp_y} + {8'd0, sp_h, 4'b0} + 16'd15;
    wire [8:0]  row_in  = screen_y - sp_y;

    // GFX byte address for current pixel pair (computed combinationally;
    // captured into spr_gfx_addr at S_DRAW_REQ entry).
    wire [15:0] tile_code = sp_code
                          + {12'd0, row_in[7:4]} * ({12'd0, sp_w} + 16'd1)
                          + {12'd0, tile_x};
    wire [3:0]  sy = row_in[3:0];
    wire [3:0]  sx = {px_pair, 1'b0};
    wire [19:0] gfx_byte_addr_next = {tile_code[12:0], sx[3], sy[3], sy[2:0], sx[2:1]};

    // Pixels extracted from the captured byte (after spr_gfx_valid)
    wire [3:0] pix_hi = pix_byte[7:4];
    wire [3:0] pix_lo = pix_byte[3:0];
    wire [15:0] dx = {7'd0, sp_x} + {8'd0, tile_x, 4'b0} + {12'd0, px_pair, 1'b0};

    always @(posedge clk) begin
        if (rst) begin
            front     <= 1'b0;
            back      <= 1'b1;
            state     <= S_IDLE;
            prev_vpos <= 9'd0;
            clr_idx   <= 8'd0;
            spr_idx   <= 8'd0;
            attr_step <= 3'd0;
            screen_y  <= 9'd0;
            sp_x <= 0; sp_y <= 0; sp_code <= 0;
            sp_pal <= 0; sp_w <= 0; sp_h <= 0;
            tile_x <= 0; px_pair <= 0;
            spr_ram_addr <= 15'd0;
            spr_gfx_req  <= 1'b0;
            spr_gfx_addr <= 24'd0;
            pix_byte     <= 8'd0;
            wr_en        <= 1'b0;
            wr_addr      <= 8'd0;
            wr_data      <= 16'd0;
        end else begin
            // Default: no write this cycle (state-specific code overrides).
            wr_en <= 1'b0;

            // Default: gfx_req drops once arbiter accepts.
            if (spr_gfx_ack) spr_gfx_req <= 1'b0;

            prev_vpos <= vpos;

            // ---- SWAP on every scanline boundary ----
            if (new_line) begin
                front    <= ~front;
                back     <= front;         // new back = old front
                if (vpos >= 9'd15 && vpos < 9'd239) begin
                    screen_y     <= vpos - 9'd15;
                    state        <= S_CLEAR;
                    clr_idx      <= 8'd0;
                end else begin
                    state <= S_IDLE;
                end
            end

            // ---- ENGINE ----
            case (state)
                S_IDLE: ;

                S_CLEAR: begin
                    wr_en   <= 1'b1;
                    wr_addr <= clr_idx;
                    wr_data <= 16'h0000;
                    if (clr_idx == 8'd255) begin
                        spr_idx      <= 8'd0;
                        spr_ram_addr <= 15'h4000;
                        state        <= S_RDEN;
                    end else
                        clr_idx <= clr_idx + 8'd1;
                end

                S_RDEN: begin
                    if (!spr_ram_data[0]) begin
                        if (spr_idx == 8'd255) state <= S_IDLE;
                        else begin
                            spr_idx      <= spr_idx + 8'd1;
                            spr_ram_addr <= 15'h4000 + {spr_idx + 8'd1, 3'd0};
                        end
                    end else begin
                        attr_step    <= 3'd0;
                        spr_ram_addr <= 15'h4000 + {spr_idx, 3'd1};
                        state        <= S_ATTR;
                    end
                end

                S_ATTR: begin
                    case (attr_step)
                        3'd0: begin sp_w <= spr_ram_data[3:0]; sp_h <= spr_ram_data[7:4];
                                    spr_ram_addr <= 15'h4000 + {spr_idx, 3'd3}; end
                        3'd1: begin sp_code <= spr_ram_data;
                                    spr_ram_addr <= 15'h4000 + {spr_idx, 3'd4}; end
                        3'd2: begin sp_x <= spr_ram_data[8:0];
                                    spr_ram_addr <= 15'h4000 + {spr_idx, 3'd6}; end
                        3'd3: begin sp_y <= spr_ram_data[8:0];
                                    spr_ram_addr <= 15'h4000 + {spr_idx, 3'd7}; end
                        3'd4: begin sp_pal <= spr_ram_data[3:0];
                                    state <= S_CHKY; end
                        default: ;
                    endcase
                    if (attr_step < 3'd4) attr_step <= attr_step + 3'd1;
                end

                S_CHKY: begin
                    // 16-bit compare avoids wrap-around: sprites with Y near
                    // 511 extend past 9-bit range and would otherwise alias
                    // to the top of the screen.
                    if ({7'd0, screen_y} >= {7'd0, sp_y} &&
                        {7'd0, screen_y} <= spr_bot) begin
                        tile_x  <= 4'd0;
                        px_pair <= 4'd0;
                        state   <= S_DRAW_REQ;
                    end else begin
                        if (spr_idx == 8'd255) state <= S_IDLE;
                        else begin
                            spr_idx      <= spr_idx + 8'd1;
                            spr_ram_addr <= 15'h4000 + {spr_idx + 8'd1, 3'd0};
                            state        <= S_RDEN;
                        end
                    end
                end

                S_DRAW_REQ: begin
                    spr_gfx_addr <= {4'd0, gfx_byte_addr_next};
                    spr_gfx_req  <= 1'b1;
                    state        <= S_DRAW_WAIT;
                end

                S_DRAW_WAIT: begin
                    if (spr_gfx_valid) begin
                        // 16-bit data is {byte at addr&~1, byte at addr|1}.
                        pix_byte <= spr_gfx_addr[0] ? spr_gfx_data[7:0]
                                                    : spr_gfx_data[15:8];
                        state    <= S_DRAW_HI;
                    end
                end

                // Split the per-pair write into two cycles so each buffer
                // sees at most one write per clock — required for clean
                // simple-dual-port M10K inference.
                S_DRAW_HI: begin
                    if (dx < 16'd256 && pix_hi != 4'hF) begin
                        wr_en   <= 1'b1;
                        wr_addr <= dx[7:0];
                        wr_data <= {1'b1, 5'd0, 2'b01, sp_pal, pix_hi};
                    end
                    state <= S_DRAW_LO;
                end

                S_DRAW_LO: begin
                    if (dx + 16'd1 < 16'd256 && pix_lo != 4'hF) begin
                        wr_en   <= 1'b1;
                        wr_addr <= dx[7:0] + 8'd1;
                        wr_data <= {1'b1, 5'd0, 2'b01, sp_pal, pix_lo};
                    end

                    if (px_pair == 4'd7) begin
                        px_pair <= 4'd0;
                        if (tile_x == sp_w) begin
                            if (spr_idx == 8'd255) state <= S_IDLE;
                            else begin
                                spr_idx      <= spr_idx + 8'd1;
                                spr_ram_addr <= 15'h4000 + {spr_idx + 8'd1, 3'd0};
                                state        <= S_RDEN;
                            end
                        end else begin
                            tile_x <= tile_x + 4'd1;
                            state  <= S_DRAW_REQ;
                        end
                    end else begin
                        px_pair <= px_pair + 4'd1;
                        state   <= S_DRAW_REQ;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
