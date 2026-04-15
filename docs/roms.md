# ROM Mapping

ROM file → MAME region → RTL destination, with byte-order/byte-swap notes for the FPGA load image.

Source of truth: `ROM_START(hachamf)` in MAME `nmk16.cpp:7903-7937`. See [`hachamf_hardware_reference.md` §F](./hachamf_hardware_reference.md#f-rom-set-hachamf-parent--clones) for full table including all clones.

## Parent set: `roms/hachamf/`

| File | Size | CRC32 | Region | RTL destination | Load notes |
|---|---|---|---|---|---|
| `7.93`        | 128 KiB | `9d847c31` | `maincpu` even | Program ROM @ `$00000` even bytes (D15..D8) | Interleave with `6.94` |
| `6.94`        | 128 KiB | `de6408a0` | `maincpu` odd  | Program ROM @ `$00001` odd bytes (D7..D0)  | Interleave with `7.93` |
| `nmk-113.bin` | 16 KiB  | `f3072715` | `protcpu`     | NMK-113 internal ROM (TLCS-900) | Only used if implementing real protection MCU |
| `1.70`        | 64 KiB  | `9e6f48fc` | `nmk004`      | NMK004 external program ROM (TLCS-90)       | Only used if running real NMK004 |
| `5.95`        | 128 KiB | `29fb04a2` | `fgtile`      | TX 8×8 GFX                                  | Linear, packed_msb |
| `91076-4.101` | 1 MiB   | `df9653a4` | `bgtile`      | BG 16×16 GFX                                | `col_2x2_group_packed_msb` (128 B/tile) |
| `91076-8.57`  | 1 MiB   | `7fd0f556` | `sprites`     | Sprite GFX                                  | **`ROM_LOAD16_WORD_SWAP`** — see swap note |
| `91076-2.46`  | 512 KiB | `3f1e67f2` | `oki1`        | OKIM6295 #1 samples                         | First 128 KiB fixed; rest in 4 banks of 128 KiB |
| `91076-3.45`  | 512 KiB | `b25ed93b` | `oki2`        | OKIM6295 #2 samples                         | Same banking as oki1 |
| `82s129.ic51` | 256 B   | `cfdbb86c` (BAD) | `nmk_irq:htiming` | H-timing PROM   | Optional — RTL can hardcode the table |
| `82s135.ic50` | 256 B   | `633ab1c9` (BAD) | `nmk_irq:vtiming` | V-timing PROM   | Drives IRQ schedule + SPRDMA |

Total: ~3.27 MiB of ROM data plus 80 KiB of MCU/PROM blobs.

## Byte-order conventions

### 68000 program ROM (`maincpu`)
MAME uses `ROM_LOAD16_BYTE`:
- `7.93` at offset `$00000` → fills even bytes (D15..D8) of the 16-bit bus.
- `6.94` at offset `$00001` → fills odd bytes (D7..D0).

For the FPGA, decide on storage:
- **Option A — store as 16-bit big-endian words**: interleave the two ROMs into a single 256 KiB image. Word at $0 = `{7.93[0], 6.94[0]}`. This matches what fx68k expects directly.
- **Option B — keep two separate byte arrays**: one BRAM per byte lane. Cleaner mapping but uses two BRAM ports.

Recommend Option A.

### Sprite GFX (`91076-8.57`) — the byte-swap gotcha
MAME loads it with `ROM_LOAD16_WORD_SWAP`. That means the file as on disk is in one byte order, and MAME swaps every adjacent pair of bytes before storing. To match the resulting in-memory layout, the FPGA load image must apply the same swap.

If you load the raw file directly: every 2-byte word is reversed vs. what `gfx_8x8x4_col_2x2_group_packed_msb` decoder expects.

**Operationally**: when the HPS_IO MRA loader streams `91076-8.57`, swap bytes 0↔1, 2↔3, 4↔5, …  Or have the MRA file declare `<part swap=true>`.

### BG GFX (`91076-4.101`) and TX GFX (`5.95`)
Loaded with plain `ROM_LOAD` — no swap. Use as-is.

### OKI sample ROMs
Plain `ROM_LOAD`, no swap. 8-bit-wide ADPCM samples, addressed linearly by the OKIM6295 with 2-bit external bank.

## GFX tile decode reminders

### TX 8×8 4bpp packed_msb (`5.95`)
- 32 bytes per 8×8 tile.
- For tile T: bytes `T*32 .. T*32+31`.
- Row R (0..7) of tile = bytes `T*32 + R*4 .. T*32 + R*4 + 3` — 4 bytes per row, 2 pixels per byte (MSB nibble = left pixel).

### BG 16×16 / sprite 16×16 4bpp `col_2x2_group_packed_msb` (`91076-4.101`, `91076-8.57`)
- 128 bytes per 16×16 tile (= 4 sub-tiles × 32 bytes).
- For tile T: bytes `T*128 .. T*128+127`.
- Sub-tile order within the 128 bytes:
  - bytes `0..31`   = top-left 8×8
  - bytes `32..63`  = bottom-left 8×8
  - bytes `64..95`  = top-right 8×8
  - bytes `96..127` = bottom-right 8×8
- Each sub-tile uses the same 8×8 packed_msb layout as TX tiles.

## Clone sets present in `roms/hachamf/`

Subdirectories contain alternate revisions. Each shares everything else with the parent.

| Set | Diff vs. parent | Notes |
|---|---|---|
| `hachamfa/` | Different `7.ic93`, `6.ic94` (program), `5.ic95` (Korean logo TX tiles) | Still uses NMK-113 |
| `hachamfb/` | Different `8.bin`, `7.bin` (program); **NO NMK-113 needed** | Bootleg with protection patched out — recommended bring-up target |
| `hachamfb2/` | Bootleg with Seibu sound board | Out of scope for first cut |
| `hachamfp/` | Prototype, no NMK-113 | Different program + GFX layout |

For initial bring-up the MRA should select **`hachamfb`** so you don't need to implement NMK-113 protection on day one.

## Suggested MRA fragment (sketch)

```xml
<misterromdescription>
  <name>Hacha Mecha Fighter (bootleg, no protection)</name>
  <setname>hachamfb</setname>
  <rbf>NMK16</rbf>

  <!-- maincpu: interleave 7.93 (even) + 6.94 (odd) into 256 KiB BE words -->
  <rom index="0" zip="hachamfb.zip">
    <interleave output="16">
      <part name="8.bin" map="01"/>
      <part name="7.bin" map="10"/>
    </interleave>
  </rom>

  <!-- fgtile -->
  <rom index="1" zip="hachamf.zip"><part name="5.95"/></rom>

  <!-- bgtile -->
  <rom index="2" zip="hachamf.zip"><part name="91076-4.101"/></rom>

  <!-- sprites: WORD_SWAP -->
  <rom index="3" zip="hachamf.zip">
    <part name="91076-8.57" swap="true"/>
  </rom>

  <!-- oki1 / oki2 -->
  <rom index="4" zip="hachamf.zip"><part name="91076-2.46"/></rom>
  <rom index="5" zip="hachamf.zip"><part name="91076-3.45"/></rom>

  <!-- nmk004 program (only if real MCU) -->
  <rom index="6" zip="hachamf.zip"><part name="1.70"/></rom>
</misterromdescription>
```

(Pseudocode — verify exact MRA tag syntax against an existing MiSTer arcade core before using.)
