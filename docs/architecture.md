# NMK_Core RTL Architecture

High-level block diagram and module responsibilities for the NMK16 / Hacha Mecha Fighter MiSTer core. For exhaustive hardware facts see [`hachamf_hardware_reference.md`](./hachamf_hardware_reference.md).

## 1. Top-level block diagram

```
                        ┌──────────────────────────┐
                        │        top.sv            │
                        │  (clocks, reset, glue)   │
                        └─────────────┬────────────┘
                                      │
        ┌─────────────────────────────┼──────────────────────────────┐
        │                             │                              │
   ┌────▼─────┐   IO bus       ┌──────▼──────┐   bus pause     ┌─────▼─────┐
   │  fx68k   │◄──────────────►│   memmap    │◄───────────────►│   irq.sv  │
   │ (68000)  │   addr/data    │  decoder +  │   IPL[2:0]      │ NMK902 +  │
   │  10 MHz  │                │  arbiter    │                 │ V-PROM    │
   └────┬─────┘                └──┬─┬─┬─┬─┬──┘                 └─────┬─────┘
        │                         │ │ │ │ │                          │
        │ HALT/BUSREQ             │ │ │ │ │                          │ DMA pulse
        │                         │ │ │ │ │ scroll/ctrl              │
        ▼                         │ │ │ │ ▼                          │
   ┌──────────┐                   │ │ │ │ ┌──────────┐                │
   │  audio   │◄────latch────────►│ │ │ │ │ tilemap  │◄───────────────┘
   │ (NMK004  │  $08000F/$08001F  │ │ │ │ │ (BG+TX)  │                │
   │  HLE or  │                   │ │ │ │ └────┬─────┘                │
   │   real)  │                   │ │ │ │      │  pixels+pri          │
   └────┬─────┘                   │ │ │ │      ▼                      │
        │                         │ │ │ │ ┌──────────┐                │
        ▼ samples                 │ │ │ │ │ sprites  │◄───────────────┘
   ┌──────────┐                   │ │ │ │ │ (4KB DMA │  trigger
   │  YM2203  │                   │ │ │ │ │ doublebuf)│
   │ +2×OKI   │                   │ │ │ │ └────┬─────┘
   └────┬─────┘                   │ │ │ │      │
        │                         │ │ │ │      ▼
        ▼                         │ │ │ │ ┌──────────┐
   audio out                      │ │ │ │ │  mixer   │
                                  │ │ │ │ │+palette  │──► RGB to HDMI/VGA
                                  │ │ │ │ └──────────┘
                                  │ │ │ │
   ROMs (load_image driven by HPS)│ │ │ │
   workram, palette, BG/TX VRAM ──┘ │ │ │
   inputs, dipswitches ─────────────┘ │ │
   GFX ROMs (BG/TX/SPR) ──────────────┘ │
   OKI sample ROMs ─────────────────────┘
```

## 2. Module responsibilities

### `top.sv`
- Clock derivation: 96 MHz PLL → 10 MHz CPU enable, 8 MHz NMK004 enable, 6 MHz pixel enable, 16 MHz OKI enable, 1.5 MHz YM2203 enable.
- Resets: cold reset (PLL locked), warm reset (NMK004 watchdog asserts), service-key reset.
- Instantiates `fx68k`, `memmap`, `tilemap`, `sprites`, `audio`, `irq`.
- HPS_IO interface (MiSTer): ROM loading, OSD config, joystick muxing, SDRAM/DDR3 if needed for GFX.
- Frame buffer / scaler glue to MiSTer `sys/` framework.

### `memmap.sv`
- 68000 address decoder per [§B of hardware reference](./hachamf_hardware_reference.md#b-main-cpu-memory-map-hachamf-parent).
- Owns: 256 KiB ROM (read-only), 64 KiB workram, 16 KiB BG VRAM, 2 KiB TX VRAM, 2 KiB palette RAM, scroll regs, `tilebank`, `flipscreen`, NMK004 latches, IN0/IN1/DSW1/DSW2 reads.
- Bus arbitration: HALT input from `audio` (NMK-113 protection MCU when implemented) freezes 68000 by gating its bus-grant.
- DTACK / wait-state generation if needed.

### `tilemap.sv`
- BG layer (16×16, 256×32 tilemap, scroll X/Y, +92 px H-shift).
- TX layer (8×8, 32×32, fixed position, +92 px H-shift, transparent on pen 15).
- VRAM dual-port: side A serves 68000, side B serves render scan.
- GFX ROM fetch: BG uses `gfx_8x8x4_col_2x2_group_packed_msb` (128 B per 16×16 tile); TX uses `gfx_8x8x4_packed_msb` (32 B per 8×8 tile).
- Outputs per-pixel: `{color[3:0], palette_bank[3:0], priority[1:0], opaque}` for BG and TX separately.
- `tilebank_w` ($080019) extends BG tile index by 4 high bits.

### `sprites.sv`
- 4 KiB DMA double-buffer (`spriteram_old`, `spriteram_old2`) — copy chain triggered by `irq.sv` SPRDMA pulse.
- During DMA: assert BUSREQ to 68000 for ~694 µs (≈6940 cycles @10 MHz).
- Per-frame sprite engine: walks 256 entries of 16 B from `spriteram_old2`.
- Per-entry: enable (W0 b0), size+flip (W1, but hachamf ignores flip — see ref §C.5.2), tile code (W3), X (W4 b9..0), Y (W6 b9..0), palette (W7 b3..0).
- Multi-tile sprites: `(w+1) × (h+1)` 16×16 tiles, codes step by 1 across rows.
- Horizontal +92 px shift, X wrap at 512.
- Sprite clock budget: 384×263 = 101,952 cycles/frame; cost = 16 + 128·w·h per sprite.
- Output to mixer with priority mask (always GFX_PMASK_2 on hachamf).

### `audio.sv`
- Phase 1 (silent): just emulate the latch register pair so the 68000 sees a sane busy bit and doesn't deadlock.
- Phase 2: NMK004 HLE — observe latch bytes, drive YM2203 + OKI commands directly. Easier and faster than running TLCS-90.
- Phase 3 (optional fidelity): instantiate a TLCS-90 soft core, load `nmk004.bin` (8 KiB internal) + external `1.70` (64 KiB).
- Hosts: YM2203 (`jt03`-style), 2× OKIM6295 (`jt6295`-style), 2-bit bank registers per OKI.
- NMK004 watchdog NMI from `$080016 b0` — generate 68000 reset if the rhythm stops.

### `irq.sv`
- Implements NMK902 + 82S135 V-PROM behavior per [§A.4 of hardware reference](./hachamf_hardware_reference.md#a4-irq-sources--levels--vectors).
- Inputs: vpos counter, hpos counter from pixel clock division.
- Outputs: `IPL[2:0]` to 68000 (autovectored), SPRDMA pulse to `sprites.sv`, VBLANK / VSYNC / HBLANK / HSYNC to video timing.
- Three IRQs on hachamf: IRQ1 (lines 68, 196), IRQ2 (line 16 = VBIN), IRQ4 (line 240 = VBOUT). Vectors $64/$68/$70.
- 82S135 PROM contents shipped as a `case` table (256 entries × 8 bits).

## 3. Cross-cutting concerns

### Clock domains
Single domain (96 MHz pixel-PLL master) with clock-enable strobes. Avoids CDC entirely. All modules accept `clk` + `ce_*` enables.

### Reset
- `rst` (synchronous, active-high) propagates to all modules.
- NMK004 watchdog can assert `rst_main` (only fx68k + memmap, not audio).

### Sprite DMA contention
68000 sees BUSREQ when sprite DMA is active. fx68k must respect BR/BG handshake. Alternative: implement as transparent bus steal — only block during cycles when sprite DMA actually accesses workram.

### Endianness
68000 is big-endian. SDRAM controllers vary. Settle convention early: workram words stored as `{high_byte, low_byte}` matching 68000 D15..D0. ROM load images byte-swapped to match (see roms.md).

## 4. Module ↔ MAME source cross-reference

| RTL module | MAME source |
|---|---|
| `top.sv` | `nmk16.cpp:5227-5263` (machine_config), `5265-5301` (hachamf_prot wrap) |
| `memmap.sv` | `nmk16.cpp:818-837` (`hachamf_map`) |
| `tilemap.sv` | `nmk16_v.cpp:34-44, 121-131, 272-293, 477-501` |
| `sprites.sv` | `nmk16spr.cpp:17-145`, `nmk16.cpp:4516-4522` (DMA) |
| `audio.sv` | `nmk16.cpp:5246-5263`, `nmk004.cpp` (full file) |
| `irq.sv` | `nmk_irq.cpp:32-252`, `nmk16.cpp:4318-4428` |
