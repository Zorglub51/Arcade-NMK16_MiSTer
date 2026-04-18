// NMK16 scanline sprite renderer — replaces the full-frame framebuffer.
//
// Matches real NMK16 hardware behaviour: per-scanline walk of the 256-entry
// sprite list, rendering intersecting sprite rows into a 256-pixel double-
// buffered line buffer. Much smaller than a 57K-entry framebuffer (512 bytes
// vs 112 KiB) and synthesizes cleanly on Cyclone V.
//
// Double buffering:
//   Buffer A / B swap each scanline. While the mixer reads from A during
//   active scan, the engine fills B for the *next* scanline. On scanline
//   boundary they swap.
//
// Timing budget:
//   At PIX_DIV=4  → 1536 master cycles/scanline. Fits ~30 active sprites.
//   At PIX_DIV=16 → 6144 master cycles/scanline. Fits 256 sprites easily.
//
// Sprite transparency: pen 15 (NMK16 convention, empirically verified).

`default_nettype none

module sprite_line (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce_pix,
    input  wire [8:0]  hpos,
    input  wire [8:0]  vpos,

    // Workram read port — sprites at words $4000..$47FF (256 × 8 words)
    output reg  [14:0] spr_ram_addr,
    input  wire [15:0] spr_ram_data,

    // Sprite GFX ROM read port (byte-wide, 1 MiB)
    output wire [19:0] spr_gfx_addr,
    input  wire [7:0]  spr_gfx_data,

    // Per-pixel output to mixer (active during scan)
    output wire [9:0]  spr_pal_idx,    // full palette index ($100 + pal*16 + color)
    output wire        spr_opaque      // 1 if pixel is non-transparent
);

    // -----------------------------------------------------------------
    // Double-buffered line buffers: 256 entries × 16 bits each
    //   [15]   = opaque flag
    //   [9:0]  = palette index
    // -----------------------------------------------------------------
    (* ramstyle = "M10K" *) reg [15:0] line_a [0:255];
    (* ramstyle = "M10K" *) reg [15:0] line_b [0:255];
    reg active_buf;                    // 0 = mixer reads A, engine writes B
                                       // 1 = mixer reads B, engine writes A

    // Mixer read — combinational from the active buffer
    wire [7:0] read_x;
    assign read_x = (hpos >= 9'd92 && hpos < 9'd348) ? hpos[7:0] - 8'd92 : 8'd0;
    wire [15:0] mixer_pixel = active_buf ? line_b[read_x] : line_a[read_x];
    assign spr_opaque  = mixer_pixel[15];
    assign spr_pal_idx = mixer_pixel[9:0];

    // -----------------------------------------------------------------
    // Engine state machine — fills the WRITE buffer for the next scanline
    // -----------------------------------------------------------------
    localparam [2:0]
        ST_IDLE       = 3'd0,
        ST_CLEAR      = 3'd1,
        ST_READ_EN    = 3'd2,
        ST_READ_ATTR  = 3'd3,
        ST_CHECK_Y    = 3'd4,
        ST_DRAW       = 3'd5,
        ST_SWAP       = 3'd6;

    reg [2:0]  state;
    reg [7:0]  clear_idx;
    reg [7:0]  sprite_idx;
    reg [2:0]  attr_step;              // sub-steps within READ_ATTR

    // Latched sprite attributes
    reg [8:0]  sp_x, sp_y;
    reg [15:0] sp_code;
    reg [3:0]  sp_pal, sp_w, sp_h;

    // Drawing state
    reg [3:0]  tile_x;                 // current tile column (0..sp_w)
    reg [3:0]  px_pair;               // byte index within tile row (0..7)

    // The scanline we're pre-rendering for (= current vpos + 1, wrapped)
    reg [8:0]  target_line;
    // Pixel row within sprite for this scanline
    wire [15:0] sprite_bottom = {7'd0, sp_y} + {8'd0, sp_h, 4'b0} + 16'd15;
    wire [8:0]  row_in_sprite = target_line - sp_y;

    // GFX address computation for current draw position
    wire [15:0] cur_tile_code = sp_code
                              + {12'd0, row_in_sprite[7:4]} * ({12'd0, sp_w} + 16'd1)
                              + {12'd0, tile_x};
    wire [3:0]  sub_y = row_in_sprite[3:0];
    wire [3:0]  sub_x_base = {px_pair, 1'b0};  // even pixel of the pair
    assign spr_gfx_addr = {cur_tile_code[12:0],
                           sub_x_base[3], sub_y[3],
                           sub_y[2:0], sub_x_base[2:1]};

    // Extract both pixels from the fetched byte
    wire [3:0] pixel_hi = spr_gfx_data[7:4];  // even pixel (left)
    wire [3:0] pixel_lo = spr_gfx_data[3:0];  // odd pixel (right)

    // Screen X for current draw pair
    wire [15:0] draw_x_base = {7'd0, sp_x}
                             + {8'd0, tile_x, 4'b0}
                             + {12'd0, px_pair, 1'b0};

    // Detect scanline boundary to trigger engine
    reg [8:0] prev_vpos;
    wire line_change = ce_pix && (vpos != prev_vpos);

    always @(posedge clk) begin
        if (rst) begin
            state      <= ST_IDLE;
            active_buf <= 1'b0;
            clear_idx  <= 8'd0;
            sprite_idx <= 8'd0;
            attr_step  <= 3'd0;
            prev_vpos  <= 9'd0;
            target_line<= 9'd0;
            sp_x <= 9'd0; sp_y <= 9'd0; sp_code <= 16'd0;
            sp_pal <= 4'd0; sp_w <= 4'd0; sp_h <= 4'd0;
            tile_x <= 4'd0; px_pair <= 4'd0;
            spr_ram_addr <= 15'd0;
        end else begin
            prev_vpos <= vpos;

            case (state)
                ST_IDLE: begin
                    if (line_change) begin
                        target_line <= (vpos < 9'd277) ? (vpos + 9'd1) : 9'd0;
                        state       <= ST_CLEAR;
                        clear_idx   <= 8'd0;
                    end
                end

                ST_CLEAR: begin
                    // Zero out the write buffer
                    if (active_buf)
                        line_a[clear_idx] <= 16'h0000;
                    else
                        line_b[clear_idx] <= 16'h0000;

                    if (clear_idx == 8'd255) begin
                        state      <= ST_READ_EN;
                        sprite_idx <= 8'd0;
                        spr_ram_addr <= 15'h4000;  // word 0 of sprite 0
                    end else
                        clear_idx <= clear_idx + 8'd1;
                end

                ST_READ_EN: begin
                    // spr_ram_data has word 0 — check enable bit
                    if (!spr_ram_data[0]) begin
                        // Disabled — skip to next sprite
                        if (sprite_idx == 8'd255)
                            state <= ST_SWAP;
                        else begin
                            sprite_idx   <= sprite_idx + 8'd1;
                            spr_ram_addr <= 15'h4000 + {sprite_idx + 8'd1, 3'd0};
                        end
                    end else begin
                        // Enabled — read attributes
                        attr_step    <= 3'd0;
                        spr_ram_addr <= 15'h4000 + {sprite_idx, 3'd1}; // word 1
                        state        <= ST_READ_ATTR;
                    end
                end

                ST_READ_ATTR: begin
                    case (attr_step)
                        3'd0: begin
                            sp_w <= spr_ram_data[3:0];
                            sp_h <= spr_ram_data[7:4];
                            spr_ram_addr <= 15'h4000 + {sprite_idx, 3'd3}; // word 3
                        end
                        3'd1: begin
                            sp_code <= spr_ram_data;
                            spr_ram_addr <= 15'h4000 + {sprite_idx, 3'd4}; // word 4
                        end
                        3'd2: begin
                            sp_x <= spr_ram_data[8:0];
                            spr_ram_addr <= 15'h4000 + {sprite_idx, 3'd6}; // word 6
                        end
                        3'd3: begin
                            sp_y <= spr_ram_data[8:0];
                            spr_ram_addr <= 15'h4000 + {sprite_idx, 3'd7}; // word 7
                        end
                        3'd4: begin
                            sp_pal <= spr_ram_data[3:0];
                            state  <= ST_CHECK_Y;
                        end
                        default: ;
                    endcase
                    if (attr_step < 3'd4)
                        attr_step <= attr_step + 3'd1;
                end

                ST_CHECK_Y: begin
                    // Does this sprite intersect target_line?
                    if (target_line >= sp_y &&
                        target_line <= sprite_bottom[8:0]) begin
                        // Yes — start drawing
                        tile_x  <= 4'd0;
                        px_pair <= 4'd0;
                        state   <= ST_DRAW;
                    end else begin
                        // No — next sprite
                        if (sprite_idx == 8'd255)
                            state <= ST_SWAP;
                        else begin
                            sprite_idx   <= sprite_idx + 8'd1;
                            spr_ram_addr <= 15'h4000 + {sprite_idx + 8'd1, 3'd0};
                            state        <= ST_READ_EN;
                        end
                    end
                end

                ST_DRAW: begin
                    // Write 2 pixels per cycle from the fetched GFX byte
                    // Pixel at draw_x_base+0 (high nibble) and draw_x_base+1 (low nibble)
                    if (draw_x_base < 16'd256 && pixel_hi != 4'hF) begin
                        if (active_buf)
                            line_a[draw_x_base[7:0]] <= {1'b1, 5'b0, 2'b01, sp_pal, pixel_hi};
                        else
                            line_b[draw_x_base[7:0]] <= {1'b1, 5'b0, 2'b01, sp_pal, pixel_hi};
                    end
                    if (draw_x_base + 16'd1 < 16'd256 && pixel_lo != 4'hF) begin
                        if (active_buf)
                            line_a[draw_x_base[7:0] + 8'd1] <= {1'b1, 5'b0, 2'b01, sp_pal, pixel_lo};
                        else
                            line_b[draw_x_base[7:0] + 8'd1] <= {1'b1, 5'b0, 2'b01, sp_pal, pixel_lo};
                    end

                    // Advance within tile row (8 byte-pairs per 16-pixel-wide tile)
                    if (px_pair == 4'd7) begin
                        px_pair <= 4'd0;
                        if (tile_x == sp_w) begin
                            // Done with this sprite — next
                            if (sprite_idx == 8'd255)
                                state <= ST_SWAP;
                            else begin
                                sprite_idx   <= sprite_idx + 8'd1;
                                spr_ram_addr <= 15'h4000 + {sprite_idx + 8'd1, 3'd0};
                                state        <= ST_READ_EN;
                            end
                        end else
                            tile_x <= tile_x + 4'd1;
                    end else
                        px_pair <= px_pair + 4'd1;
                end

                ST_SWAP: begin
                    active_buf <= ~active_buf;
                    state      <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
