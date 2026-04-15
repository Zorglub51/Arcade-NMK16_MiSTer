# Arcade-NMK16_MiSTer

Work-in-progress MiSTer FPGA core for NMK's 1991 arcade board — first target: **Hacha Mecha Fighter** (`hachamfb` unprotected bootleg set).

## Status: Phase 7 v1 — smoke-test build

- ✅ 68000 (FX68K) + address decoder + IRQ scheduler + VRAM/palette/workram
- ✅ BG (16×16) + TX (8×8) tilemap rendering, correctly decoded from MAME-verified GFX format
- ✅ Sprite engine with DMA + 4 KB list walk + multi-tile + priority mixer
- ✅ Keyboard/joystick input routing
- ✅ NMK004 echo stub so attract mode animates (no real audio yet)
- ✅ Phase 4 SDL harness runs on Mac — title screen "HACHA MECHA FIGHTER" renders correctly in sim
- ✅ Phase 7 v1 `emu.sv` MiSTer wrapper, Quartus 17 project ready to build
- ⏳ **Phase 7 v2**: SDRAM controller for BG/sprite GFX (2 MiB won't fit in BRAM)
- ⏳ **Phase 5**: real audio via `jt03` (YM2203) + `jt6295` (OKIM6295) + NMK004 HLE
- ⏳ **Phase 6**: NMK-113 protection MCU for parent `hachamf` set

See [`PROGRESS.md`](PROGRESS.md) for the phase-by-phase journey and [`deploy/README.md`](deploy/README.md) for the tester handoff package.

## Layout

```
NMK_Core/
├── rtl/                   ← Core RTL (SystemVerilog)
│   ├── top.sv             ← (stub for now; real top lives in testbench and deploy)
│   ├── memmap.sv          ← (stub)
│   ├── tilemap.sv         ← BG + TX layers, fully working
│   ├── sprites.sv         ← (stub; real sprite engine inlined in phase4 top for now)
│   ├── audio.sv           ← (stub; Phase 5)
│   ├── irq.sv             ← NMK16 IRQ schedule
│   └── cpu/fx68k/         ← vendored FX68K (GPL v3)
├── testbench/             ← Verilator + SDL sim harnesses (Phase 0-4)
│   ├── Makefile
│   ├── nmk16_phase*_top.sv
│   ├── nmk16_phase*_main.cpp
│   └── build_hachamfb_hex.py   ← ROM → hex/bin converter (CRC-checked)
├── deploy/                ← Phase 7 v1 package for tester
│   ├── source/            ← Quartus-buildable source (for you, the builder)
│   └── release/           ← drop-in package for end-users
├── docs/                  ← Hardware reference + phase docs
├── roms/                  ← NOT in git — your local MAME ROM set (gitignored)
├── PROGRESS.md            ← phase-by-phase journey
├── README.md              ← this file
└── LICENSE                ← GPL v3
```

## Development flow (Mac-first)

Verilator + SDL on macOS covers everything up through Phase 4. Then Phase 7 builds an FPGA bitstream via Quartus for real-hardware validation.

```bash
# Build & run the interactive SDL harness (Phase 4)
cd testbench
python3 build_hachamfb_hex.py      # one-time; CRC-verifies local ROMs
make run_phase4_sdl                 # SDL window, keyboard controls
```

Headless trace captures for debugging: `make run_phase4` with the `--frames N --dump-frames a,b,c` flags on the binary.

## ROM files (user-supplied)

The build scripts expect MAME-named ROMs at:

```
roms/hachamf/
├── 8.bin, 7.bin            (hachamfb/ subdir in full set)
├── 5.95, 91076-4.101, 91076-8.57
└── 91076-2.46, 91076-3.45
```

These are © NMK 1991 and **not distributed with this repo**. Users must supply their own legal copy.

## Licensing

GPL v3. All vendored code is GPL-compatible:

- **FX68K** (`rtl/cpu/fx68k/`): © Jorge Cwik — GPL v3 — <https://github.com/ijor/fx68k>
- **MiSTer framework** (`deploy/source/sys/`): © MiSTer Devs — GPL v2+ — <https://github.com/MiSTer-devel/Template_MiSTer>
- **Core RTL + documentation** (everything else): GPL v3

Compiled `.rbf` bitstreams are derivative works and are GPL-covered; redistribute freely with sources (or a link to sources).

## Reference

- Hardware mapping derived from MAME `src/mame/nmk/nmk16.cpp` (see `docs/hachamf_hardware_reference.md` for cited details)
- Jotego JTCORES audio cores (targeted for Phase 5): <https://github.com/jotego/jtcores>
- MiSTer Template: <https://github.com/MiSTer-devel/Template_MiSTer>
