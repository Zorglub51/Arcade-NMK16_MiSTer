# 68000 Memory Map — Quick Reference

Hacha Mecha Fighter (parent set `hachamf`). Single-page lookup for RTL writing. Authoritative source: [`hachamf_hardware_reference.md` §B](./hachamf_hardware_reference.md#b-main-cpu-memory-map-hachamf-parent), itself derived from MAME `nmk16.cpp:818-837`.

## Address regions

| Range | Size | R/W | Device | Notes |
|---|---|---|---|---|
| `$000000–$03FFFF` | 256 KiB | R   | Program ROM         | `7.93` (even), `6.94` (odd) |
| `$040000–$07FFFF` | 256 KiB | —   | unmapped (BERR)     | |
| `$080000.W`       | 2 B     | R   | IN0                 | coins, service, start (active-low) |
| `$080002.W`       | 2 B     | R   | IN1                 | P1+P2 sticks/buttons (active-low) |
| `$080008.W`       | 2 B     | R   | DSW1                | low byte; lives, difficulty, lang, flip |
| `$08000A.W`       | 2 B     | R   | DSW2                | low byte; demo, coinage |
| `$08000F.B` (odd) | 1 B     | R   | NMK004 → main latch | |
| `$080015.B` (odd) | 1 B     | W   | flipscreen          | bit 0 |
| `$080016.W`       | 2 B     | W   | NMK004 watchdog NMI | bit 0 → NMK004 NMI line |
| `$080019.B` (odd) | 1 B     | W   | tilebank (BG)       | high 4 bits of BG tile index |
| `$08001F.B` (odd) | 1 B     | W   | main → NMK004 latch | |
| `$08C001/3/5/7.B` | 4 B     | W   | BG scroll           | XH/XL/YH/YL (low byte of word writes) |
| `$088000–$0887FF` | 2 KiB   | R/W | Palette RAM         | 1024 × 16-bit, RRRRGGGGBBBBRGBx |
| `$090000–$093FFF` | 16 KiB  | R/W | BG VRAM (layer 0)   | 16×16 tilemap, 256×32 tiles |
| `$094000–$09BFFF` | —       | —   | unmapped            | |
| `$09C000–$09C7FF` | 2 KiB   | R/W | TX (FG) VRAM        | 8×8 tilemap, 32×32 tiles |
| `$0A0000–$0EFFFF` | —       | —   | unmapped            | |
| `$0F0000–$0FFFFF` | 64 KiB  | R/W | Main work RAM       | sprite list at `$0F8000–$0F8FFF` (DMA src); shared with NMK-113 |

Everything from `$100000` upward is unmapped on the 68000 side. The NMK-113 protection MCU bus-masters into `$000000–$0FFFFF` via the same arbiter (it sees the 68000's address space, not its own).

## Input bit definitions

### IN0 — `$080000.W` byte 0 (active-low)

| Bit | Function   |
|---|---|
| 0 | COIN1     |
| 1 | COIN2     |
| 2 | SERVICE1  |
| 3 | START1    |
| 4 | START2    |
| 5 | unknown   |
| 6 | unknown   |
| 7 | unknown   |

### IN1 — `$080002.W` 16-bit (active-low)

| Bit | Function   | | Bit | Function   |
|---|---|---|---|---|
| 0 | P1 Right  | | 8  | P2 Right  |
| 1 | P1 Left   | | 9  | P2 Left   |
| 2 | P1 Down   | | 10 | P2 Down   |
| 3 | P1 Up     | | 11 | P2 Up     |
| 4 | P1 Btn 1  | | 12 | P2 Btn 1  |
| 5 | P1 Btn 2  | | 13 | P2 Btn 2  |

### DSW1 — `$080008.W` low byte

| Bits | Field | Values |
|---|---|---|
| 0   | Flip Screen          | 1=Off / 0=On |
| 1   | Language             | 0=English / 1=Japanese |
| 3..2 | Difficulty          | 11=Norm 01=Easy 10=Hard 00=Hardest |
| 4   | unused               | |
| 5   | unused               | |
| 7..6 | Lives               | 11=3 10=4 01=2 00=1 |

### DSW2 — `$08000A.W` low byte

| Bits | Field | Values |
|---|---|---|
| 0   | unused               | |
| 1   | Demo Sounds          | 1=On / 0=Off |
| 4..2 | Coin B              | 7-entry table — see ref |
| 7..5 | Coin A              | 7-entry table — see ref |

## Scroll register layout

Four 8-bit-wide registers at odd-byte addresses (writes use low byte of 16-bit write):

| Address  | Field          | Bits |
|---|---|---|
| `$08C001` | scrollX hi (b15..b8)  | 8 |
| `$08C003` | scrollX lo (b7..b0)   | 8 |
| `$08C005` | scrollY hi (b15..b8)  | 8 |
| `$08C007` | scrollY lo (b7..b0)   | 8 |

Effective scrollX/Y are 16-bit. BG tilemap is internally shifted by `+92 px` to align with the sprite generator's `videoshift`.

## Sprite RAM (in workram)

- Source: `$0F8000–$0F8FFF` (4 KiB, 256 entries × 16 B).
- DMA-copied each frame to internal double buffer when SPRDMA pulse fires (~line 242).
- Per-entry layout (byte offsets, big-endian words):

| Off | Width | Field |
|---|---|---|
| `+0`  | W | bit 0 = enable (visible) |
| `+2`  | W | b9=flipY b8=flipX b7..4=h-1 b3..0=w-1 (flips ignored on hachamf) |
| `+4`  | W | unused |
| `+6`  | W | tile code (16-bit) |
| `+8`  | W | X position b9..0 |
| `+10` | W | unused |
| `+12` | W | Y position b9..0 |
| `+14` | W | b3..0 = palette select (16 banks of 16) |

## Palette RAM

- 1024 entries × 2 bytes at `$088000–$0887FF`.
- Word format: `RRRR GGGG BBBB R G B x` (bits 15..0).
- Per-channel intensity: top nibble + low LSB extension bit = 5 bits.
- Banks: BG `$000-$0FF`, sprites `$100-$1FF`, TX `$200-$2FF`, unused `$300-$3FF`.

## IRQs

| IRQ | Vector | Trigger (V-PROM) | Purpose |
|---|---|---|---|
| 1 | `$64` | scanlines 68 & 196 | mid-screen / split |
| 2 | `$68` | scanline 16 (VBIN) | display |
| 4 | `$70` | scanline 240 (VBOUT) | vblank |

All autovectored (68000 internal autovector — board ties to VPA equivalent).
SPRDMA pulse from V-PROM bit 0, ~scanline 242.
