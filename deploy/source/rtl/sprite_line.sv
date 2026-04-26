// NMK16 scanline sprite renderer — clean rewrite.
//
// Simple double-buffered design:
//   - Two 256×16-bit line buffers (A and B).
//   - 'front' register selects which the mixer reads; engine writes the other.
//   - On each vpos change: swap front, clear the new back buffer, walk sprites.
//   - Engine writes are latched to the back buffer determined at swap time.
//   - No generation counter — explicit 256-cycle clear. Budget: ~1500 cycles
//     for sprites + 256 clear = ~1756. At PIX_DIV=4 budget is 1536 — tight
//     but sprites that don't finish are simply clipped (partial rendering, no desync).

`default_nettype none

module sprite_line (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce_pix,
    input  wire [8:0]  hpos,
    input  wire [8:0]  vpos,

    output reg  [14:0] spr_ram_addr,
    input  wire [15:0] spr_ram_data,

    output wire [19:0] spr_gfx_addr,
    input  wire [7:0]  spr_gfx_data,

    output wire [9:0]  spr_pal_idx,
    output wire        spr_opaque
);

    // -----------------------------------------------------------------
    // Line buffers.  [15]=opaque  [9:0]=palette index.  Bit 15=0 means empty.
    // -----------------------------------------------------------------
    reg [15:0] buf_a [0:255];
    reg [15:0] buf_b [0:255];

    reg front;   // 0 → mixer reads A, engine writes B
                 // 1 → mixer reads B, engine writes A
    reg back;    // latched at swap: which buffer engine writes to (0=A,1=B)

    // Mixer — read from front buffer
    wire [7:0] mx = (hpos >= 9'd92 && hpos < 9'd348) ? (hpos[7:0] - 8'd92) : 8'd0;
    wire [15:0] front_px = front ? buf_b[mx] : buf_a[mx];
    assign spr_opaque  = front_px[15];
    assign spr_pal_idx = front_px[9:0];

    // -----------------------------------------------------------------
    // Engine FSM
    // -----------------------------------------------------------------
    localparam [2:0]
        S_IDLE  = 3'd0,
        S_CLEAR = 3'd1,
        S_RDEN  = 3'd2,
        S_ATTR  = 3'd3,
        S_CHKY  = 3'd4,
        S_DRAW  = 3'd5;

    reg [2:0]  state;
    reg [7:0]  clr_idx;
    reg [7:0]  spr_idx;
    reg [2:0]  attr_step;
    reg [8:0]  sp_x, sp_y;
    reg [15:0] sp_code;
    reg [3:0]  sp_pal, sp_w, sp_h;
    reg [3:0]  tile_x, px_pair;
    reg [8:0]  screen_y;  // screen-space Y for this fill (0..223)

    // Detect vpos change (1 cycle after irq.sv updates vpos via NBA)
    reg [8:0] prev_vpos;
    wire new_line = (vpos != prev_vpos);

    // Y range check
    wire [15:0] spr_bot = {7'd0, sp_y} + {8'd0, sp_h, 4'b0} + 16'd15;
    wire [8:0]  row_in  = screen_y - sp_y;

    // GFX address for current pixel pair
    wire [15:0] tile_code = sp_code
                          + {12'd0, row_in[7:4]} * ({12'd0, sp_w} + 16'd1)
                          + {12'd0, tile_x};
    wire [3:0] sy = row_in[3:0];
    wire [3:0] sx = {px_pair, 1'b0};
    assign spr_gfx_addr = {tile_code[12:0], sx[3], sy[3], sy[2:0], sx[2:1]};

    wire [3:0] pix_hi = spr_gfx_data[7:4];
    wire [3:0] pix_lo = spr_gfx_data[3:0];
    wire [15:0] dx = {7'd0, sp_x} + {8'd0, tile_x, 4'b0} + {12'd0, px_pair, 1'b0};

    // Write one pixel to back buffer
    task automatic write_back(input [7:0] x, input [15:0] val);
        if (back) buf_a[x] <= val;
        else      buf_b[x] <= val;
    endtask

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
        end else begin
            prev_vpos <= vpos;

            // ---- SWAP on every scanline boundary ----
            if (new_line) begin
                front    <= ~front;        // flip display buffer
                back     <= front;         // old front becomes new back (for engine)
                // Start fill if this line is in the visible area.
                // screen_y = next display line in screen coords.
                // After swap, 'front' (new value) will be read during the
                // NEXT scanline (vpos). The engine fills 'back' for that line.
                // Screen-space: vpos 16..239 = screen 0..223.
                // Start filling one line ahead of display so the buffer is
                // ready when the mixer reads it during the NEXT vpos active area.
                // Mixer during vpos=V reads screen_y = V - 16.
                // We fill during vpos=V-1 for screen_y = V - 16 = (V-1) - 15.
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
                S_IDLE: ; // nothing to do until next swap

                S_CLEAR: begin
                    write_back(clr_idx, 16'h0000);
                    if (clr_idx == 8'd255) begin
                        spr_idx      <= 8'd0;
                        spr_ram_addr <= 15'h4000;
                        state        <= S_RDEN;
                    end else
                        clr_idx <= clr_idx + 8'd1;
                end

                S_RDEN: begin
                    if (!spr_ram_data[0]) begin
                        // disabled — next
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
                        state   <= S_DRAW;
                    end else begin
                        if (spr_idx == 8'd255) state <= S_IDLE;
                        else begin
                            spr_idx      <= spr_idx + 8'd1;
                            spr_ram_addr <= 15'h4000 + {spr_idx + 8'd1, 3'd0};
                            state        <= S_RDEN;
                        end
                    end
                end

                S_DRAW: begin
                    if (dx < 16'd256 && pix_hi != 4'hF)
                        write_back(dx[7:0], {1'b1, 5'd0, 2'b01, sp_pal, pix_hi});
                    if (dx + 16'd1 < 16'd256 && pix_lo != 4'hF)
                        write_back(dx[7:0] + 8'd1, {1'b1, 5'd0, 2'b01, sp_pal, pix_lo});

                    if (px_pair == 4'd7) begin
                        px_pair <= 4'd0;
                        if (tile_x == sp_w) begin
                            if (spr_idx == 8'd255) state <= S_IDLE;
                            else begin
                                spr_idx      <= spr_idx + 8'd1;
                                spr_ram_addr <= 15'h4000 + {spr_idx + 8'd1, 3'd0};
                                state        <= S_RDEN;
                            end
                        end else
                            tile_x <= tile_x + 4'd1;
                    end else
                        px_pair <= px_pair + 4'd1;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
