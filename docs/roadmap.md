# Implementation Roadmap

Phased plan from cold start to playable on real MiSTer hardware. Each phase ends in a runnable, demonstrable artifact tested on Mac via Verilator+SDL before any FPGA synthesis.

The strategy mirrors what worked for the Sega System 32 core: **MAME as oracle**, dump frames at fixed points, diff against MAME, fix divergences.

## Phase 0 — Sim scaffold (Mac-only, no RTL behavior yet)
**Goal**: window opens, shows a test pattern, can be quit. No game logic.

- Copy `sim/Makefile`, `sim/sys32_sdl.cpp`, `sim/sys32_sim.cpp` to `NMK_Core/testbench/` and rename to `nmk16_*`.
- Replace top-module include with `top.sv` stub that drives a static color pattern.
- Verify Verilator + SDL build on macOS, window opens at 256×224 upscaled.
- Add PPM frame dump on keypress (steal from system32 `sys32_sim.cpp`).

**Done when**: `cd NMK_Core/testbench && make && ./nmk16_sim` shows a pattern.

## Phase 1 — CPU + workram + program ROM running
**Goal**: 68000 fetches and runs hachamfb code; can observe PC trace.

- Vendor FX68K (`https://github.com/ijor/fx68k`) into `rtl/cpu/fx68k/`.
- `top.sv`: instantiate fx68k, generate clock enables.
- `memmap.sv`: implement ROM read at `$00000-$3FFFF`, workram at `$F0000-$FFFFF`. Everything else returns `$FFFF`, ignores writes.
- Stub IRQs as deasserted (CPU runs uninterrupted).
- Sim harness: load `hachamfb` byte-interleaved ROM image into a Verilog `$readmemh` array.
- Trace: every cycle the CPU executes, log PC + opcode to `nmk16_trace.log`.

**Done when**: trace shows reset vector fetch → stack/PC setup → enters main loop without crashing on a BERR. Compare initial PCs against MAME log.

## Phase 2 — Inputs, dipswitches, video timing skeleton
**Goal**: CPU sees inputs and survives long enough to set up VRAM.

- `memmap.sv`: implement IN0/IN1 reads (driven by SDL keyboard), DSW1/DSW2 (constant from sim args), `flipscreen_w`, `tilebank_w`, scroll regs (latched, no effect yet), NMK004 latch stub.
- `irq.sv`: scanline counter, hardcoded V-PROM table, drive IPL[2:0] with IRQ2 on line 16, IRQ4 on line 240, IRQ1 on lines 68/196. Generate VBLANK/HSYNC strobes.
- `top.sv`: 256×224 active raster output (fixed solid color while no tilemap yet).
- Audio stub: latch reads always return 0. NMK004 watchdog: silently swallow writes to `$080016` for now (don't actually reset).

**Done when**: trace shows CPU hitting VBLANK ISR and tilemap-setup code. Compare main-loop PCs against MAME at frame 5/10/30.

## Phase 3 — BG + TX tilemaps
**Goal**: title screen renders.

- `tilemap.sv`: BG and TX layers per architecture doc.
- Wire BG VRAM (`$090000-$093FFF`), TX VRAM (`$09C000-$09C7FF`), palette RAM (`$088000-$0887FF`).
- GFX ROMs: `5.95` for TX, `91076-4.101` for BG. Load in sim via `$readmemh`.
- `tilemap.sv` outputs per-pixel `{color, palette_bank, priority}`. Mixer in `top.sv` consumes both BG and TX, applies palette lookup, outputs RGB.
- Palette decode per `RRRRGGGGBBBBRGBx`.
- Mind the +92 px H-shift on both layers.

**Done when**: PPM dump at frame 60/120 visually matches MAME's `hachamfb` title screen (sprites still missing, but background and text correct).

## Phase 4 — Sprites + DMA
**Goal**: full visual parity (minus protection-gated states).

- `sprites.sv`: 4 KiB double-buffer, DMA from `$0F8000-$0F8FFF` triggered by V-PROM bit 0 (~line 242).
- BUSREQ to fx68k for ~694 µs during DMA.
- Sprite engine: walk 256 entries, fetch GFX from `91076-8.57` (with byte-swap applied), output pixels with priority mask.
- Mixer: BG → sprites → TX, with sprite-under-TX priority.

**Done when**: gameplay PPM dumps match MAME for `hachamfb` at frames 60/120/300/600. Replay attract mode visually identical.

## Phase 5 — Audio (NMK004 HLE first)
**Goal**: music + sound effects.

- `audio.sv` v1: HLE — observe latch byte writes, command-by-command translate to YM2203 / OKI register writes.
- Vendor a YM2203 core (Jotego `jt03` or similar) and OKIM6295 core (`jt6295`).
- 2-bit OKI bank registers per OKI.
- NMK004 watchdog NMI rhythm — start by always succeeding (no reset).
- Sim: dump audio to a WAV file; compare envelope/timing against MAME.

**Done when**: title BGM and in-game SFX play at correct pitch, no obvious dropouts.

## Phase 6 — Switch target to `hachamf` (parent) + protection
**Goal**: parent set boots and plays.

Two paths, pick one:
- **6a (HLE)**: reverse-engineer NMK-113's effect on workram by diffing `hachamf` vs `hachamfb` 68000 ROMs. Patch the relevant workram words in `audio.sv` (or a dedicated `protection.sv`).
- **6b (faithful)**: vendor a TLCS-900 soft core, instantiate NMK-113 with `nmk-113.bin`, implement the HALT/BUSREQ handshake (port 6 = `0x08`/`0x0B`), wire port 7 = `0x0C` constant.

Recommend 6a first; 6b later if needed.

**Done when**: `hachamf` parent attract loop + start-coin-play sequence works.

## Phase 7 — MiSTer FPGA bring-up
**Goal**: works on real DE10-Nano.

- Wrap `top.sv` in MiSTer `sys/` framework: HPS_IO, video scaler, SDRAM (or DDR3) for GFX ROMs that don't fit in BRAM.
- Memory budget: 1 MiB BG GFX + 1 MiB sprite GFX + 1 MiB OKI samples = won't fit in BRAM; need SDRAM.
- Write MRA file (see `roms.md`).
- Synthesize, fit, load on DE10-Nano, verify with real CRT/HDMI output.

**Done when**: game runs on hardware at correct speed, controls work, no audio glitches.

## Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| FX68K bus-cycle accuracy issues vs MAME timing | Med | Compare cycle-counted traces; FX68K is well-validated, accept its timing as reference |
| NMK-113 HLE wrong → game hangs in a way bootleg doesn't | Med | Stick with `hachamfb` until everything else works; tackle protection last |
| YM2203 / OKI cores have integration bugs | Low | Both Jotego cores are battle-tested in JTCORES |
| 92-px H-shift forgotten somewhere | High (easy mistake) | Documented in 3 places now; bake into module port docs |
| Sprite WORD_SWAP forgotten on `91076-8.57` | High | Documented in roms.md; verify with first sprite render |
| MAME-vs-RTL frame-dump comparison tool needs writing | Med | Reuse system32's PPM diff approach |
| BG GFX 1 MiB blows BRAM budget on Cyclone V | Med | Plan SDRAM cache from Phase 3, not Phase 7 |

## Key references during build

- Hardware facts: [`hachamf_hardware_reference.md`](./hachamf_hardware_reference.md)
- Memory map: [`memmap.md`](./memmap.md)
- Architecture: [`architecture.md`](./architecture.md)
- ROMs and load order: [`roms.md`](./roms.md)
- MAME source: <https://github.com/mamedev/mame/tree/master/src/mame/nmk>
- FX68K: <https://github.com/ijor/fx68k>
- JTCORES (YM2203, OKIM6295): <https://github.com/jotego/jtcores>
- MiSTer template: <https://github.com/MiSTer-devel/Template_MiSTer>
