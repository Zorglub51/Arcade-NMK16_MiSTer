# Core status — Phase 7 v1 (smoke test)

## Verified in simulation (Verilator on macOS)

These are confirmed-working behaviours from our testbench harness. The exact same RTL modules are in this deploy package.

| Subsystem | Status | Evidence |
|---|---|---|
| 68000 CPU (FX68K) | ✅ Runs hachamfb code correctly | Phase 1 trace: reset vectors match, boot executes, main loop IRQs serviced |
| Address decode | ✅ ROM / workram / VRAM / palette / IO all correct | Phase 2 trace: correct bytes land in correct regions |
| IRQ generator | ✅ IPL transitions and IACK match docs | Phase 2 trace: line 16 IRQ2, line 68/196 IRQ1, line 240 IRQ4 |
| Input routing | ✅ IN0/IN1 byte positions match MAME | Phase 5 Stage 1 fix: IN0 mirrors on both bytes |
| Scroll registers | ✅ Latched correctly | Phase 2 trace: scroll regs written at end-of-frame |
| BG tilemap | ✅ Renders full game background | Phase 3: MAME-accurate first-stage sky + mountains |
| TX tilemap | ✅ 8×8 packed_msb decode correct | Phase 3 logic verified |
| Sprite engine | ✅ DMA + render + multi-tile | Phase 4: dinosaur + mecha characters render cleanly |
| Sprite transparency | ✅ Pen 15 (empirically verified) | Phase 4 bug fix |
| Palette decoder | ✅ `RRRRGGGGBBBBRGBx` → RGB24 | Phase 3 |
| NMK004 echo stub | ✅ Unblocks attract mode | Phase 5 Stage 1 |

## Phase 7 v1 (this handoff) — FPGA-side

| Item | v1 state |
|---|---|
| `emu.sv` top module | ✅ Written (`NMK16.sv`) |
| Quartus project files | ✅ `NMK16.qsf`/`.qpf`/`.sdc` |
| PLL 50→96 MHz | ✅ Vendored from template |
| HPS_IO integration | ✅ Wired for joystick + ROM download + OSD |
| Program ROM via ioctl | ✅ Loads 256 KiB into BRAM on `ioctl_index=0` |
| Workram / VRAM / palette | ✅ All BRAM, fit within Cyclone V SE budget |
| Sprite framebuffer | ✅ BRAM (90 M10K blocks) |
| BG/TX/sprite GFX ROMs | ❌ **Not wired** — data pins tied to 0 |
| Audio | ❌ Silent — `AUDIO_L/R = 0` |
| Video output | ⚠️ Should work structurally, but picture will be partial (no tile patterns) |
| Timing closure | ⚠️ Unverified — tilemap uses combinational GFX fetch; may need pipeline stages if Quartus fails timing |

## Known-unknowns

Things I can't verify without running on hardware:

1. **Will Quartus synthesize without errors?** The SystemVerilog constructs used are all standard; BRAM inference attributes (`(* ramstyle = "M10K" *)`) are Altera-specific but should be recognised. Biggest risk is the sprite FSM having a `case` construct Quartus doesn't like.
2. **Does it fit in the Cyclone V SE (5CSEBA6U23I7)?** Our count: ~365 M10K blocks. Limit: 397. Tight but should fit.
3. **Does 96 MHz close timing?** Most likely yes — the combinational chain through tilemap is the longest, ~5 levels of logic per pixel. Maybe 20 ns. Fine at 96 MHz (10.4 ns period). If not, we pipeline.
4. **Is the `hps_io` CONF_STR syntax current?** It matches the Template_MiSTer as of April 2026. If the tester has a newer sys/ package, may need touch-up.
5. **Will the MRA loader deliver ROMs in the order our ioctl decoder expects?** `ioctl_index=0` for maincpu is standard MiSTer convention; I've followed it.

## Deferred (will be Phase 7 v2, v3, etc.)

- **SDRAM integration for GFX ROMs** (2 MiB of BG + sprites). This is the single biggest gap blocking a real-looking picture.
- **Real audio** (Phase 5): vendor jt03 + jt6295 from JTCORES, NMK004 HLE state machine, wire to AUDIO_L/R with proper 48 kHz resample.
- **NMK-113 protection** (Phase 6): support parent `hachamf` set by emulating the protection MCU's bus-mastering behaviour.
- **MiSTer-standard features**: scanlines, shadowmask, hq2x, rotate (none of the NMK games are rotated though), save states if useful.
