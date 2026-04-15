# NMK16 core — source (for you, the builder)

This is the SystemVerilog source you'll compile with Quartus to produce `NMK16.rbf`. Only you need this folder. Your tester and end-users see only `../release/`.

## Your steps, in order

1. **Install Quartus Prime Lite 17.0 or 17.1** — see [QUICKSTART.md](QUICKSTART.md). One-time, ~1 hour.
2. **Compile** — `quartus_sh --flow compile NMK16` from this folder. ~15 min.
3. **Locate the output** — `output_files/NMK16.rbf` (~5–10 MB).
4. **Ship** — copy `NMK16.rbf` into `../release/`, rename with today's date (`NMK16_YYYYMMDD.rbf`), hand the whole `release/` folder to your tester.

## Files in this folder

| File | What |
|---|---|
| `NMK16.sv` | MiSTer `emu` top module — hps_io, PLL, ROM loader, joystick mux, wraps our core |
| `NMK16.qsf`/`.qpf`/`.sdc` | Quartus 17 project |
| `files.qip` | RTL file list (read by `NMK16.qsf`) |
| `rtl/nmk16_core.sv` | Core — CPU + VRAM + palette + tilemap + sprite + mixer |
| `rtl/tilemap.sv` | BG (16×16) + TX (8×8) tile layers |
| `rtl/irq.sv` | Scanline counter + NMK16 IRQ schedule |
| `rtl/cpu/fx68k/` | [FX68K](https://github.com/ijor/fx68k) 68000 core (GPL v3) |
| `rtl/pll*` | 50 → 96 MHz PLL (from Template_MiSTer) |
| `sys/` | MiSTer framework (vendored from Template_MiSTer) |
| `hachamfb.mra` | ROM manifest — copy this into `../release/` alongside the `.rbf` |
| [`STATUS.md`](STATUS.md) | What v1 does / doesn't do — read before testing |
| [`QUICKSTART.md`](QUICKSTART.md) | Install + build walkthrough |

## About v1 (important to set expectations)

v1 is a **smoke-test** build. Expected tester experience:

- Core loads on MiSTer ✅
- CPU runs the real `hachamfb` program ✅
- Controls reach the game ✅
- Graphics show palette colours + moving shapes (NOT real tile art — GFX ROMs not wired yet)
- No audio

v1 is about confirming FPGA integration, not playing the game. v2 will add SDRAM + real GFX; v3 adds audio.

## Licensing

GPL v3 throughout. Attribution:

- This core: GPL v3
- **FX68K** (`rtl/cpu/fx68k/`): © Jorge Cwik, GPL v3 — <https://github.com/ijor/fx68k>
- **MiSTer framework** (`sys/`, PLL): © MiSTer Devs, GPL v2+ — <https://github.com/MiSTer-devel/Template_MiSTer>
- **Game ROMs**: © NMK 1991 — not distributed; users supply their own legal copy
