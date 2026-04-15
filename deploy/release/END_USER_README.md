# Hacha Mecha Fighter — MiSTer install guide

This folder contains what you need to put Hacha Mecha Fighter on your MiSTer DE10-Nano. **You do NOT need Quartus or any programming tools.**

## What you need

1. A running MiSTer on a DE10-Nano (any recent firmware).
2. The core bitstream: `NMK16_YYYYMMDD.rbf` — provided in this folder.
3. The MRA manifest: `hachamfb.mra` — also in this folder.
4. The game ROM files (MAME naming): `hachamf.zip` and `hachamfb.zip`. **These are not provided** — you must supply them yourself. Search for the MAME set matching your region's laws.

## Install

Turn off the MiSTer, pull the SD card, and copy the files to these exact locations:

```
/media/fat/
├── _Arcade/
│   ├── hachamfb.mra                   ← from this folder
│   └── cores/
│       └── NMK16_20260415.rbf         ← bitstream file
└── games/
    └── mame/
        ├── hachamf.zip                ← your ROM set
        └── hachamfb.zip               ← your ROM set
```

(If `games/mame/` does not exist, create it.)

Put the SD card back, boot the MiSTer.

## Run

1. Main menu → **Arcade**
2. Scroll to **Hacha Mecha Fighter (bootleg)** — select
3. Wait a few seconds for ROMs to load from SD

## Controls

Default MiSTer arcade mapping:

| Action | Controller | Keyboard |
|---|---|---|
| Insert coin | Select / Back | 5 |
| Start 1P | Start | 1 |
| Start 2P | Start (P2 pad) | 2 |
| Move | D-pad / stick | Arrow keys |
| Button 1 | A | LCtrl |
| Button 2 | B | LAlt |
| Open OSD | — | F12 |

Remap anything you like from the MiSTer main OSD → Input settings.

## Expected appearance — v1 is a test build

This core is **v1 (smoke-test)**. Expect:

- Partial image — palette colors and moving shapes, but graphics won't look like real tile art
- No sound
- Attract mode runs but the title screen looks abstract

This is normal for v1. If you get *any* picture and inputs react, the build is working. Real graphics and sound are coming in v2 / v3.

## Troubleshooting

| Symptom | Probable cause |
|---|---|
| Core name not in Arcade menu | `.mra` not in `/media/fat/_Arcade/` or filename typo |
| "Unknown ROM" error on load | `.rbf` missing or filename inside the `.mra` doesn't match |
| "ROM: error X" when loading | `hachamf.zip` / `hachamfb.zip` missing or in wrong folder |
| Screen stays black | Give it 5–10 seconds; ROMs take time to load over SD |
| Crashes / resets | Report to core developer with MiSTer firmware version |
