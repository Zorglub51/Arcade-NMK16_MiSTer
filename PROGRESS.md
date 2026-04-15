# NMK_Core — project progress log

Living log of phase-by-phase decisions, bugs found, gotchas worth remembering. Written during development, preserved here so future-me and collaborators don't have to rediscover them. Entries are roughly chronological.

---

Started 2026-04-15. Separate from the existing system32 V60 work — different folder (`NMK_Core/`), different CPU (M68000), different game (hachamf).

**Layout** (folder tree the user requested):
```
NMK_Core/
├── rtl/        top.sv memmap.sv tilemap.sv sprites.sv audio.sv irq.sv  (all stubs)
├── roms/       hachamf/ + hachamfa/ hachamfb/ hachamfb2/ hachamfp/
├── docs/       hachamf_hardware_reference.md (844 lines, MAME-cited)
│               architecture.md memmap.md roms.md roadmap.md
└── testbench/  (empty — Phase 0 work)
```

**Hardware (as of MAME ~April 2026 — verify before relying)**:
- Main CPU: M68000 @ 10 MHz (NOT V53, despite earlier guesses).
- Sound: NMK004 (TLCS-90 MCU + 8 KB internal ROM) drives YM2203 + 2× OKIM6295.
- Protection: NMK-113 (TLCS-900) for parent set; bus-masters into 68000 mainram.
- Video: 256×224 @ 56.2 Hz, 6 MHz pixel clock. BG (16×16) + TX (8×8) + 256 sprites. **+92 px H-shift on everything**.
- Sprite RAM lives in workram at $0F8000-$0F8FFF, DMA'd to internal double buffer ~line 242.

**Why:** building this core is the user's next project after system32; explicit goal is Mac-first development using the same MAME-as-oracle workflow (PPM frame dumps, state diffs).

**How to apply:**
- Roadmap target: bring up `hachamfb` bootleg first (no NMK-113 needed) before tackling parent.
- Reuse system32's `sim/Makefile` + `sys32_sdl.cpp` + `sys32_sim.cpp` as testbench scaffold.
- Plan to use FX68K (https://github.com/ijor/fx68k) for 68000 — do not write a CPU from scratch.
- Plan to use Jotego cores (jt03 YM2203, jt6295 OKIM6295) for sound.
- Sprite GFX `91076-8.57` is `ROM_LOAD16_WORD_SWAP` — needs byte-pair swap on load (easy to forget, called out in docs/roms.md).
- **Phase 0 done (2026-04-15)**: `NMK_Core/testbench/` builds with `make`. `nmk16_test_pattern.sv` (256x224 active, 384x278 total, 6 MHz, NMK16 timing) + `nmk16_sim_main.cpp` (Verilator+SDL, ESC quits, F12 dumps PPM, supports `--frames N --dump-frame1`) + `Makefile`. Verified headlessly with `SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software`; PPM dumps the expected 8 color bars.
- For headless sim runs on macOS use: `SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software perl -e 'alarm(5); exec @ARGV' ./obj_dir/sim_nmk16_test_pattern --frames N`. (No `timeout` cmd on macOS; perl alarm respects the 5s timeout rule.)
- Verilator on this Mac: `/opt/homebrew/bin/verilator` 5.046; SDL2 2.32.10 via Homebrew.
- **Phase 1 done (2026-04-15)**: FX68K vendored at `rtl/cpu/fx68k/` (GPL3, from ijor/fx68k). Phase 1 testbench (`nmk16_phase1_top.sv` + `nmk16_phase1_main.cpp`) has fx68k + ROM + WRAM + permissive bus stub (DTACK always, IPL tied off). Reset vector verified: SSP=$0FFF0, PC=$0212. CPU executes valid hachamfb code — first thing it does is dispatch a 16-byte sound-command table from $200 to NMK004 latch at $08001F with `MOVE.W #$10,D1; MOVE.B (A0)+,D0; MOVE.W D0,(A1); DBF D2,$22A` delay loop. Build with `make phase1`, run with `make run_phase1` → trace at `nmk16_trace.log`.
- **FX68K + Verilator gotchas**: needs `--no-assert` (unique cases fire on time-0 X-prop) plus this lint mask: `-Wno-{BLKANDNBLK,UNOPTFLAT,CASEX,LATCH,ALWCOMBORDER,INITIALDLY,ZERODLY,VARHIDDEN,SELRANGE,CMPCONST,DECLFILENAME,TIMESCALEMOD,WIDTHEXPAND,WIDTHTRUNC,UNUSEDSIGNAL,UNUSEDPARAM,PINCONNECTEMPTY,CASEINCOMPLETE,MULTIDRIVEN,SYNCASYNCNET}`. `microrom.mem` and `nanorom.mem` must be in CWD at runtime — Makefile copies them to `obj_dir/`.
- Hachamfb ROM image: `roms/hachamfb_prog.hex` (256 KiB, big-endian words, one per line). Built by `testbench/build_hachamfb_hex.py` which CRC-verifies inputs against MAME (8.bin=$14845b65, 7.bin=$069ca579).
- **Phase 2 done (2026-04-15)**: `rtl/irq.sv` real (scanline counter + hardcoded hachamf events: IRQ2@16 / IRQ4@240 / IRQ1@68,196 / SPRDMA@242, latched until IACK). `testbench/nmk16_phase2_top.sv` adds memory map (ROM, WRAM, BG/TX VRAM, palette RAM, IO regs incl. scroll/flip/tilebank/NMK004-latch). VPAn drives autovector during IACK. CPU enters steady-state main loop ~frame 17 — every frame thereafter: IACK level 2 at line 16, level 1 at lines 68/196, level 4 at line 240. Run with `make run_phase2` → `nmk16_irq.log`, with optional `--bus-trace ../nmk16_bus.log`.
- **Bus-write timing gotcha (2026-04-15)**: in fx68k, oEdb is NOT valid at the cycle ASn falls — it's valid by the time UDSn/LDSn assert. Latching writes on `as_falling` captures stale data ($0000 instead of $FFFF) and breaks the workram RAM test in hachamfb boot ($7E5E `MOVE.W D1,(A0); CMP.W (A0),D1; BNE.W $7F36`). Correct pattern: latch writes on the *rising* edge of UDSn/LDSn (= end of bus cycle, data definitely valid). Cost me an hour of trace digging — bake into `memmap.sv` once we get there.
- **Sim speed knob**: `PIX_DIV` parameter in phase2 top divides ce_pix relative to clk. Setting PIX_DIV=16 lets the CPU run ~16× more bus cycles per simulated frame, so the long boot delays (17 outer × 61441 inner DBF iterations = ~5M CPU bus cycles) finish in ~17 sim frames instead of ~300. Loses real-time accuracy but irrelevant for trace-based validation.
- **Phase 3 done (2026-04-15)**: Real `rtl/tilemap.sv` (BG 256×32 tiles 16×16 4bpp col_2x2_group + TX 32×32 tiles 8×8 4bpp packed_msb, +92 px H-shift, combinational fetches). `testbench/nmk16_phase3_top.sv` adds GFX ROM loading (`hachamf_bg.hex` 1 MiB, `hachamf_tx.hex` 128 KiB), palette decoder (RRRRGGGGBBBBRGBx → 5b/ch → 8b), mixer. Renders hachamfb first-stage background correctly — blue sky + stylized clouds + mountain silhouettes (see `docs/phase3_renders/frame_00040.png`). Frame is static from frame 35 onward because no sprites yet. `build_hachamfb_hex.py` now produces all three hex files in one pass.
- **Phase 4 done (2026-04-15)**: sprite engine inline in `nmk16_phase4_top.sv` (to extract into `rtl/sprites.sv` later). 256-entry×16B sprite list at workram `$0F8000–$0F8FFF`, multi-tile `(w+1)×(h+1)` with codes incrementing row-major, pen **15** transparent (not pen 0 — empirically verified: pen 0 drew solid colored rectangles around each sprite). FSM: IDLE→CLEAR (57344 px) → per sprite READ+DRAW 1 px/clock. Frame buffer `reg [15:0] spr_fb[]` 256×224 entries, mixer is `BG < sprite < TX`. Triggered by irq.sv sprdma pulse @ line 242. Sprite GFX from `hachamf_spr.hex` — byte-pair swapped on build (`ROM_LOAD16_WORD_SWAP`). Attract-mode renders the dinosaur + mecha transformation sprites cleanly (see `docs/phase4_renders/frame_00060.png`).
- **Simplifications still deferred from Phase 4**: (1) no CPU halt during DMA — real HW stalls CPU ~694 µs; in sim we don't care because the CPU is in its VBLANK ISR at the trigger moment. (2) no double-buffer — sprite engine reads workram live; OK because the attract-mode flow doesn't mutate spriteram during VBLANK. (3) sprite X-wrap at 512 is clipped instead of wrapped. (4) flipX/flipY ignored. Address these when promoting the engine from testbench-inline to a reusable `sprites.sv`.
- **Phase 5 (Stage 1) done (2026-04-15)**: minimal NMK004 HLE stub. Key discovery via bus trace: the sound-queue handler at ROM `$04A2` does `CMP.B $08000F,D3; BEQ advance; RTS` — it expects the NMK004 to **echo back** the last command byte written to `$08001F`. A one-line echo in the `$08000F` read mux (`io_rd = {nmk004_to_snd, nmk004_to_snd}`) unblocks attract-mode animation. No real audio yet.
- **Input byte-position bug (2026-04-15)**: IN0 (coin/service/start) in NMK16 lives in the **low byte** of the 16-bit word at `$080000` (MAME `PORT_START("IN0")` with `PORT_BIT(0x01..)` = bits 0..4 = LOW byte). I initially wrote `{in0_keys, 8'h00}` which puts it in the high byte, so the CPU reading `MOVE.B $080001, D0` got `$00` = all active-low bits asserted = all buttons pressed → game auto-started, skipping attract. Mirror on both bytes (`{in0_keys, in0_keys}`) is the safe fix. Same fix applied to DSW1/DSW2. When porting to real `memmap.sv`, mirror all 8-bit inputs on both bytes.
- **Title screen animates (frames 50-80)**: "HACHAMECHA FIGHTER" logo slams down with animated clouds. Color count climbs 10→42 as animation progresses. See `docs/phase4_renders/frame_00080.png`.
- Next: revisit remaining goals. Options: (A) real audio via jt03+jt6295+HLE command mapping; (B) SDL+keyboard input for interactive play; (C) refactor the Phase 4 testbench into `rtl/sprites.sv` and `rtl/memmap.sv` proper, with dual-port VRAMs and sprite double-buffer; (D) tackle the remaining visual artefacts (letterboxing in frame 80 might be legitimate title effect or a missing pipeline step).

**Sim performance notes (2026-04-15)** — at PIX_DIV=16, Verilator sim runs ~0.47 s of wall time per rendered frame. Init is already <20 ms (not the bottleneck). Switched `$readmemh` → `$fread` on `.bin` files anyway (smaller files, same speed). Verilator `--threads 4` makes sim 10× SLOWER on this model (overhead > parallelism benefit for small design). Practical consequence: 200-frame captures take ~90 s wall time. A strict 2 s alarm on render runs is too tight to show gameplay — must either allow an explicit exception for render captures, or snapshot CPU+RAM post-boot.

**Phase 4 SDL harness (2026-04-15)**: `testbench/nmk16_phase4_sdl.cpp` + Makefile target `phase4_sdl`. Live SDL window (768×672 upscaled), MAME-style key map: `5`=COIN, `1`/`2`=START1/2, `9`=SERVICE1, arrows+Z+X=P1, R/D/F/G+Q/W=P2, `F12`=PPM, `P`=pause, `ESC`=quit. Builds with `make phase4_sdl`, run with `make run_phase4_sdl`. Frame rate ~2 fps in window (same 0.47 s/frame sim throughput).

**Phase 7 v1 handoff done (2026-04-15)**: `deploy/` folder ready for tester. Contents: `NMK16.sv` (MiSTer emu top), `NMK16.qsf`/`.qpf`/`.sdc` (Quartus 17.0), `rtl/nmk16_core.sv` (core extracted from testbench, no `$readmemh`, external ROM ports), `rtl/tilemap.sv`+`irq.sv`+`cpu/fx68k/`, vendored `sys/` from Template_MiSTer, `mra/hachamfb.mra`, 4 markdown docs (README / STATUS / QUICKSTART / TESTER_NOTES). **Smoke-test build only**: program ROM + CPU + VRAM/palette/workram all in BRAM (should fit ~365 of 397 M10K blocks); GFX ROM data pins tied to 0 (display will be colored rectangles, not real art); audio silent. Gets us to "can Quartus synthesize? does framework integration work? do inputs reach CPU?" — not a playable core.

Next: Phase 7 v2 = add SDRAM controller, wire GFX ROMs, get real picture. Likely involves vendoring jtframe_sdram or similar from JTCORES. Also Phase 5 (real audio) and Phase 6 (NMK-113 for parent hachamf set) remain.
