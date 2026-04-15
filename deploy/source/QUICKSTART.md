# Quickstart — build + package NMK16.rbf

## 1. Prerequisites

- **Quartus Prime Lite 17.0** or **17.1** (Windows or Linux). **Not 20+** — MiSTer IP assumes 17.x.
  - Download: <https://www.intel.com/content/www/us/en/software/programmable/quartus-prime/download.html>
- For quick testing on your own MiSTer:
  - DE10-Nano + SD card + MiSTer firmware
  - Legally-sourced `hachamf.zip` and `hachamfb.zip` MAME ROM sets

## 2. Build the bitstream

From this `source/` folder:

```bash
# One-time per build: regenerate build_id (timestamp + git SHA embedded in .rbf)
quartus_sh -t sys/build_id.tcl

# Full synthesis + fit + timing + RBF generation
quartus_sh --flow compile NMK16
```

Takes ~5–15 minutes on a modern desktop. Output: `output_files/NMK16.rbf` (~5-10 MB).

### If the build fails

| Error | Likely cause | Fix |
|---|---|---|
| `Can't find file "rtl/cpu/fx68k/microrom.mem"` | Wrong cwd | Run from `source/` |
| `Insufficient M10K blocks` | BRAM budget exceeded | Tell me — may need to move sprite FB to M20K |
| `Timing not met (negative slack)` | 96 MHz too aggressive | Tell me — pipeline stages needed in `tilemap.sv` |
| `Can't resolve module sys_top` | `sys/sys.qip` missing | Verify `sys/` folder intact (51 files expected) |
| Many "unused port" warnings on `emu` | v1 only uses a subset of MiSTer ports | Ignore |

If stuck, keep the last ~100 lines of the Quartus log + the Fitter report (`output_files/NMK16.fit.rpt`, especially Resource Usage + Failed Paths) — both help me triage.

## 3. Package for the tester

```bash
# From the deploy/ root:
cp source/output_files/NMK16.rbf release/NMK16_$(date +%Y%m%d).rbf
```

`release/` now contains:

```
release/
├── NMK16_YYYYMMDD.rbf     ← the bitstream you just built
├── hachamfb.mra
└── END_USER_README.md     ← tester follows this
```

Zip `release/` and hand it to your tester.

## 4. (Optional) Test yourself first

Exactly the same steps as your tester will follow — see `../release/END_USER_README.md`. Install on your own MiSTer's SD card:

```
/media/fat/
├── _Arcade/
│   ├── hachamfb.mra
│   └── cores/NMK16_YYYYMMDD.rbf
└── games/mame/
    ├── hachamf.zip         ← your own copy
    └── hachamfb.zip        ← your own copy
```

Boot → MiSTer menu → Arcade → Hacha Mecha Fighter (bootleg). Expect: partial picture, no audio, controls reach the game (see STATUS.md for exact v1 scope).
