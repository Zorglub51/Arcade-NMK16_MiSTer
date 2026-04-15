# Hacha Mecha Fighter / NMK16 Hardware Reference

Target: MiSTer FPGA core for the NMK 1991 arcade board running **Hacha Mecha Fighter** (parent set `hachamf`).

All facts below are derived from MAME master (`src/mame/nmk/`) at commit HEAD as of April 2026, fetched directly from <https://github.com/mamedev/mame/tree/master/src/mame/nmk>. Citations take the form `nmk16.cpp:LINE` and refer to that upstream tree.

---

## 0. Hardware summary (one-liner)

NMK "standard" 68000 + NMK004 (Toshiba TMP90C840 based sound MCU) + NMK-113 (Toshiba TMP91640 based protection MCU) board. Low-res 256x224 video, one 16x16 scrolling BG layer, one 8x8 TX (foreground) layer, 16x16 DMA-buffered sprites, 1024-entry RGB444 palette, YM2203 + two OKIM6295. Source header: `nmk16.cpp:15-16`:
```
Hacha Mecha Fighter proto  1991 NMK        68000 NMK004        YM2203 2xOKIM6295  Low-Res
Hacha Mecha Fighter        1991 NMK        68000 NMK004        YM2203 2xOKIM6295  Low-Res
```

MAME driver entry (`nmk16.cpp:10697`):
```
GAME( 1991, hachamf, 0, hachamf_prot, hachamf_prot, tdragon_prot_state, empty_init, ROT0, "NMK", ... )
```
So parent `hachamf` uses **machine_config = `hachamf_prot`** (= `hachamf(config)` + NMK-113 MCU, `nmk16.cpp:5265-5301`) and **address map = `hachamf_map`** (`nmk16.cpp:818-837`).

---

## A. CPU subsystem

### A.1 Main CPU

- **Chip**: Motorola 68000 (MAME uses `M68000`, PCB uses MC68000P10). `nmk16.cpp:5230`:
  ```cpp
  M68000(config, m_maincpu, 10000000); // MC68000P10, 10 MHz ?
  ```
- **Clock**: 10 MHz (comment notes "?" — not confirmed on PCB, but consistent with 10/12/16 MHz XTAL set listed in comment `nmk16.cpp:5226` "OSC : 10MHz, 12MHz, 16MHz").
- **Endianness**: Big-endian (68000 native). All 16-bit memory accesses are high-byte-first; `ROM_LOAD16_BYTE` alternates even/odd — even ROM (`7.93` = `0x00000` = D15..D8), odd ROM (`6.94` = `0x00001` = D7..D0). See `nmk16.cpp:7905-7906`.
- **Address width**: 24 bits external.
- **No NEC V53 variant exists for hachamf.** The whole NMK16 driver header (`nmk16.cpp:6-35`) only lists 68000 for this board family. V53 is used in unrelated NMK boards (Arcadia/Rapid Hero uses `tmp90c841`, `nmk16.cpp:22`). Different *revisions* of hachamf use different auxiliary chips but all are 68000-based:
  | Set | CPU | Sound | Protection |
  |---|---|---|---|
  | `hachamf` (parent) | 68000 @10 MHz | NMK004 | **NMK-113 (TMP91640)** |
  | `hachamfa` | 68000 @10 MHz | NMK004 | NMK-113 |
  | `hachamfb` (bootleg) | 68000 @10 MHz | NMK004 | none (patched) |
  | `hachamfp` (proto) | 68000 @10 MHz | NMK004 | none |
  | `hachamfb2` (bootleg) | 68000 @10 MHz | Z80 + Seibu Raiden sound | none |

### A.2 Sound CPU (NMK004)

The NMK004 is an opaque custom chip. Internal dump has date string `900315` and version `V-00` (`nmk16.cpp:43-45`). Inside:

- **Core**: Toshiba **TMP90C840AF** (8-bit TLCS-90), QFP64, with 8 KiB internal ROM (`nmk004.cpp:141`):
  ```cpp
  TMP90840(config, m_cpu, DERIVED_CLOCK(1,1));
  ```
- **Internal ROM**: 8 KiB, filename `nmk004.bin`, CRC `8ae61a09`, SHA1 `f55f9e6bb55bfa56f9f797518dca032aaa3f6a32` (`nmk004.cpp:100`). *Required by MAME, supplied as `nmk004` device region.*
- **Clock**: DERIVED_CLOCK(1,1) of the NMK004 device clock. Parent sets it to **8 MHz**: `nmk16.cpp:5246` `NMK004(config, m_nmk004, 8000000);`
- **NMK004 internal memory map** (`nmk004.cpp:83-95`):
  | TLCS-90 addr | Contents |
  |---|---|
  | `0x0000-0x1FFF` | Internal ROM (NMK004 internal) |
  | `0x2000-0xEFFF` | External ROM (the `nmk004` region, `1.70`) |
  | `0xF000-0xF7FF` | 2 KiB internal work RAM |
  | `0xF800-0xF801` | YM2203 R/W |
  | `0xF900`        | OKIM6295 #0 R/W |
  | `0xFA00`        | OKIM6295 #1 R/W |
  | `0xFB00`        | Latch from 68000 (to_nmk004) |
  | `0xFC00`        | Latch to 68000 (to_main) |
  | `0xFC01`        | OKI #0 bank-switch (2 bits) |
  | `0xFC02`        | OKI #1 bank-switch (2 bits) |

### A.3 Main-CPU <-> NMK004 communication

Bidirectional 8-bit latch + "watchdog NMI":

- **Main -> NMK004 write**: `0x08001F` (odd byte). Writes into a latch the NMK004 reads at `0xFB00`. `nmk16.cpp:830`:
  ```cpp
  map(0x08001f, 0x08001f).w(m_nmk004, FUNC(nmk004_device::write));
  ```
  `nmk004.cpp:16-20`:
  ```cpp
  void nmk004_device::write(uint8_t data) { ...; to_nmk004 = data; }
  ```

- **Main <- NMK004 read**: `0x08000F` (odd byte). Reads the latch the NMK004 writes at `0xFC00`. `nmk16.cpp:826`:
  ```cpp
  map(0x08000f, 0x08000f).r(m_nmk004, FUNC(nmk004_device::read));
  ```

- **Watchdog NMI** at `0x080016.W`: bit 0 asserts/deasserts NMI into NMK004 — game must toggle this periodically or NMK004 resets the 68000. `nmk16.cpp:224-230`:
  ```cpp
  void nmk16_state::nmk004_x0016_w(u16 data) {
      // watchdog scheme: generating an NMI on the NMK004 keeps a timer alive
      // if that timer expires the NMK004 resets the system
      m_nmk004->nmi_w(BIT(data, 0) ? ASSERT_LINE : CLEAR_LINE);
  }
  ```
  The reverse (NMK004 resetting 68000) is wired by `port4_w` on TLCS-90, `nmk004.cpp:28-34`:
  ```cpp
  void nmk004_device::port4_w(uint8_t data) {
      // bit 0x01 is set to reset the 68k
      m_reset_cb(BIT(data, 0) ? ASSERT_LINE : CLEAR_LINE);
  }
  ```

- **Latches are "synchronized"** via `machine().scheduler().synchronize()` (`nmk004.cpp:17, 23, 67, 73`). For RTL purposes this just means the latch is 8 bits wide, no handshake status bit; software polls.

### A.4 IRQ sources / levels / vectors

The IRQ generator is a separate device (**NMK902 counters + 82S135 V-timing PROM**) emulated by `nmk_irq_device`. Source: `nmk_irq.cpp` and header comment in `nmk_irq.cpp:4-145`.

- V-timing PROM format (`nmk_irq.cpp:80-89`, also `nmk16.cpp:4318-4328`): 256 × 8 bits, addressed by `(vpos/2 + 0x75) % length`:

  | Bit | Meaning (active state) |
  |---|---|
  | 0 | Sprite DMA trigger (active low) |
  | 1 | VSYNC (active low) |
  | 2 | VBLANK (active low) |
  | 3 | unused |
  | 4 | IPL0 (active high) |
  | 5 | IPL1 (active high) |
  | 6 | IPL2 (active high) |
  | 7 | Interrupt trigger (rising edge latches IPL\[2:0] as the level) |

- For `hachamf` the 82S135 dump is `633ab1c9` (shared with tdragon and macross; `nmk16.cpp:7936`). Comment block at `nmk16.cpp:4395-4422` and `nmk_irq.cpp:118-137` gives triggered levels:

  | IRQ | Scanline(s) | Meaning | Inhibited? |
  |---|---|---|---|
  | **IRQ1** | 68 and 196 | Half-blanking / mid-screen | active |
  | **IRQ2** | 16 (end of VBLANK = VBIN) | Display interrupt | active |
  | **IRQ4** (VBOUT) | 240 (start of VBLANK) | V-blanking interrupt | active |
  | IRQ3 | — | Only used by `powerins`, never on hachamf | n/a |

- Acknowledgement: MAME uses `HOLD_LINE` (`nmk16.cpp:4424-4428`):
  ```cpp
  void nmk16_state::main_irq_cb(u8 data) {
      if (data != 0) m_maincpu->set_input_line(data, HOLD_LINE);
  }
  ```
  On 68000 `HOLD_LINE` means the line stays asserted until auto-vectored acknowledge clears it (the CPU does auto-vector ack since the NMK016 hardware ties `VPA` / uses the internal autovector). So **use 68000 auto-vectored IRQ1/IRQ2/IRQ4** (vectors `$64/$68/$70`).

- The `nmk_irq_device` scan callback fires at every scanline; on even lines it indexes the 82S135 and on the rising edge of bit 7 asserts the level `bitswap<3>(val, IPL2_INDEX, IPL1_INDEX, IPL0_INDEX)` (`nmk_irq.cpp:211-252`).

- **Sprite DMA** is triggered by PROM bit 0 (rising edge). See section C.6.

- "Hacky" fallback for boards with unknown PROMs (NOT used by hachamf): `nmk16.cpp:4480-4509` fixes VBIN=16, VBOUT=240, SPRDMA=VBOUT+2, IRQ1 at VBIN+52 and +128.

---

## B. Main-CPU memory map (hachamf parent)

Source: `hachamf_map()` at `nmk16.cpp:818-837`. Word-addressable; `umask16(0x00ff)` on scroll regs means writes use low byte (odd address).

| Start | End | Size | R/W | Device | Bit-width | Notes |
|---|---|---|---|---|---|---|
| `0x000000` | `0x03FFFF` | 256 KiB | R | Program ROM | 16 | 68000 code. Byte-interleaved from 2x 128 KiB EPROMs (ROMs `7.93` hi, `6.94` lo; see §F). |
| `0x040000` | `0x07FFFF` | 256 KiB | — | unmapped | — | 68000 BERR here. |
| `0x080000` | `0x080001` | 2 B | R | IN0 port | 16 | Coins / service / start (see §B.1). |
| `0x080002` | `0x080003` | 2 B | R | IN1 port | 16 | P1/P2 joysticks + buttons. |
| `0x080008` | `0x080009` | 2 B | R | DSW1 | 16 (low byte used) | See §B.2. |
| `0x08000A` | `0x08000B` | 2 B | R | DSW2 | 16 (low byte used) | See §B.2. |
| `0x08000F` | `0x08000F` | 1 B odd | R | NMK004 -> main latch | 8 | `to_main`. |
| `0x080015` | `0x080015` | 1 B odd | W | `flipscreen_w` | 8 | Bit 0 = flip screen. `nmk16_v.cpp:272-275`. |
| `0x080016` | `0x080017` | 1 W | W | `nmk004_x0016_w` | 16 (bit 0) | NMK004 watchdog NMI line. |
| `0x080019` | `0x080019` | 1 B odd | W | `tilebank_w` | 8 | Sets `m_bgbank` (BG tile bank, × 4096 tiles). `nmk16_v.cpp:284-293`. |
| `0x08001F` | `0x08001F` | 1 B odd | W | `nmk004_device::write` | 8 | Main -> NMK004 latch. |
| `0x088000` | `0x0887FF` | 2 KiB | R/W | Palette RAM | 16 | 1024 colors × 2 bytes, format RRRRGGGGBBBBRGBx (palette has RGBx low bit extensions; `nmk16.cpp:5240`). |
| `0x08C000` | `0x08C007` | 8 B | W | Scroll regs layer 0 | 8 (umask `0x00ff`) | 4 bytes at odd offsets 1,3,5,7 (written via `scroll_w<0>`). See §C.4. |
| `0x090000` | `0x093FFF` | 16 KiB | R/W | BG videoram (layer 0) | 16 | 16x16 tilemap, see §C.3. `bgvideoram_w<0>`. |
| `0x094000` | `0x09BFFF` | — | — | unmapped | | |
| `0x09C000` | `0x09C7FF` | 2 KiB | R/W | TX (FG) videoram | 16 | 8x8 text layer, 32x32 tiles on-screen. `txvideoram_w`. |
| `0x0A0000` | `0x0EFFFF` | — | — | unmapped | | |
| `0x0F0000` | `0x0FFFFF` | 64 KiB | R/W | Main work RAM | 16 | Contains sprite list (copied by DMA), shared with NMK-113 MCU. Contents include: sprite table at `0xF0000+sprdma_base` (default `0x8000` so sprites live at `0xF8000-0xF8FFF`, 4 KiB = 256 entries of 16 bytes). |

Note: No explicit spriteram region — sprites are resident in mainram and copied by DMA to an internal 4 KiB double-buffer (see §C.6). `m_sprdma_base = 0x8000` default (`nmk16.h:52`).

### B.1 IN0 (0x080000.W) - byte 0

`nmk16.cpp:1849-1857` (hachamf_prot port).

| Bit | Function (active low) |
|---|---|
| 0 | COIN1 |
| 1 | COIN2 |
| 2 | SERVICE1 |
| 3 | START1 |
| 4 | START2 |
| 5 | unknown |
| 6 | unknown |
| 7 | unknown (test-mode related in some games) |

### B.1b IN1 (0x080002.W) - 16-bit

`nmk16.cpp:1859-1875`. All active low.

| Bit | Function |
|---|---|
| 0 | P1 Right |
| 1 | P1 Left |
| 2 | P1 Down |
| 3 | P1 Up |
| 4 | P1 Button 1 |
| 5 | P1 Button 2 |
| 6-7 | unknown |
| 8 | P2 Right |
| 9 | P2 Left |
| 10 | P2 Down |
| 11 | P2 Up |
| 12 | P2 Button 1 |
| 13 | P2 Button 2 |
| 14-15 | unknown |

### B.2 DSW1 (0x080008.W low byte) / DSW2 (0x08000A.W low byte)

From `INPUT_PORTS_START(hachamf_prot)` `nmk16.cpp:1877-1925`. DIP positions are labeled SW1:1..8 / SW2:1..8 on the PCB silk. Active values listed below are the ROM-read value (1 = DIP off for most, standard MAME convention).

**DSW1** (`0x080008` low byte):

| Bits | DIP | Name | Values |
|---|---|---|---|
| 0 | SW1:8 | Flip Screen | 1=Off 0=On |
| 1 | SW1:7 | Language | 0=English 1=Japanese (note default is 0/English per MAME default) |
| 3..2 | SW1:6,5 | Difficulty | `11`=Normal, `01`=Easy, `10`=Hard, `00`=Hardest |
| 4 | SW1:4 | Unknown | 1=Off 0=On |
| 5 | SW1:3 | Unknown | 1=Off 0=On |
| 7..6 | SW1:2,1 | Lives | `11`=3, `10`=4, `01`=2, `00`=1 |

**DSW2** (`0x08000A` low byte):

| Bits | DIP | Name | Values |
|---|---|---|---|
| 0 | SW2:8 | Unused | 1=On 0=Off |
| 1 | SW2:7 | Demo Sounds | 1=On 0=Off |
| 4..2 | SW2:6,5,4 | Coin B | `111`=1C_1C, `110`=1C_2C, `101`=1C_3C, `100`=3C_1C, `011`=2C_1C, `010`=3C_1C*, `001`=1C_4C, `000`=Free Play (*see MAME table, some entries duplicate) |
| 7..5 | SW2:3,2,1 | Coin A | `111`=1C_1C, `110`=2C_1C, `101`=1C_3C, `100`=4C_1C, `011`=1C_2C, `010`=3C_1C, `001`=1C_4C, `000`=Free Play |

(Full mapping verbatim from MAME `nmk16.cpp:1908-1925`.)

### B.3 No watchdog at 0x080000 etc.

There is no classic watchdog write register. The "watchdog" is the NMK004 NMI toggle at `0x080016`. Lose the NMI rhythm and NMK004 will pull main CPU RESET low.

### B.4 Shared with NMK-113 MCU

The whole `0x000000-0x0FFFFF` space is *readable and writable by the NMK-113 via its own external bus*. See `tdragon_prot_map` `nmk16.cpp:5104-5108`:
```cpp
map(0x000000, 0x0fffff).rw(FUNC(tdragon_prot_state::mcu_side_shared_r),
                          FUNC(tdragon_prot_state::mcu_side_shared_w));
```
When the MCU wants to access bus, it writes port 6 = `0x08` to **HALT** the 68000 (line asserted), does its reads/writes, then writes `0x0B` to release HALT (`nmk16.cpp:5018-5036`). In RTL this is the same as asserting BGACK / HALT to the 68000. Effectively the MCU acts as a DMA bus master into the 68000 memory.

---

## C. Video hardware

### C.1 Screen timing (low-res)

Config: `set_screen_lowres()` at `nmk16.cpp:4352-4362`:
```cpp
m_screen->set_raw(XTAL(12'000'000)/2, 384, 92, 348, 278, 16, 240);
```
- **Pixel clock**: 12 MHz / 2 = **6 MHz**.
- **Total H**: 384 px/line.
- **Active H**: 92..348 = **256 px** visible.
- **H sync**: pixels 0..31 (32 px).
- **H blank**: 0..91 and 348..383 (92+36 = 128 px total blank).
- **Total V**: 278 lines.
- **Active V**: 16..239 = **224 lines** visible.
- **V blank**: lines 0..15 and 240..277 (54 lines).
- **Line rate**: 6 MHz / 384 = 15625 Hz (standard 15 kHz).
- **Frame rate**: 15625 / 278 ≈ **56.2 Hz** (MAME computes 56.2246 Hz ≈ standard NMK 56-ish; source comment gives 56.18... in several places).
- **Screen origin for rendering**: visible x is shifted by `videoshift=92` on sprite gen (see C.5).

H-timing also governed by 82S129 PROM (`hachamf:82s129.ic51` CRC `cfdbb86c`). Format (`nmk_irq.cpp:32-39`):

| H-PROM bit | Meaning |
|---|---|
| 0 | Line counter trigger (active low) |
| 1 | HSYNC (active low) |
| 2 | HBLANK (active low) |
| 3 | Unused (except gunnail/raphero) |

For low-res the H-counter starts at 0x40 and runs to 0xFF (192 steps × 2 px = 384 px).

### C.2 Tile layers (count, size, depth)

From `gfx_macross` gfxdecode `nmk16.cpp:4186-4190` (Hacha Mecha Fighter uses this, `nmk16.cpp:5239`):

```cpp
GFXDECODE_ENTRY( "fgtile",  0, gfx_8x8x4_packed_msb,               0x200, 16 ) // TX
GFXDECODE_ENTRY( "bgtile",  0, gfx_8x8x4_col_2x2_group_packed_msb, 0x000, 16 ) // BG
GFXDECODE_ENTRY( "sprites", 0, gfx_8x8x4_col_2x2_group_packed_msb, 0x100, 16 ) // sprites
```

| Layer | Name | Tile size | Bits/pixel | Tilemap size (VRAM) | On-screen size | Palette base | Transparent pen | Scrolling |
|---|---|---|---|---|---|---|---|---|
| **BG** | bgtile (16x16) | 16x16 | 4bpp | 256×32 tiles = 4096×512 px (`nmk16_v.cpp:121-131`, `macross` inherits) | 256×224 | `0x000-0x0FF` (16 × 16 entries) | — (opaque) | X+Y, per-frame |
| **TX** (FG) | fgtile (8x8) | 8x8 | 4bpp | 32×32 tiles = 256×256 px (`nmk16_v.cpp:121-128`) | 256×224 | `0x200-0x2FF` | pen 15 | None |

Both layers use the same video-start routine `VIDEO_START_MEMBER(nmk16_state, macross)` which calls `manybloc` setup then applies `scrolldx(92, 92)` offsets on both the BG and TX tilemaps (to align with the sprite gen's 92-pixel video shift).

**Important 16x16 tile decode**: `gfx_8x8x4_col_2x2_group_packed_msb` means each 16x16 tile is stored as **4 × (8x8 4bpp packed) sub-tiles arranged column-major** in the GFX ROM — a 2x2 grid of 8x8 tiles per 16x16 "logical tile". One 16x16 tile occupies 128 bytes (4 × 32 bytes/8x8 4bpp). Equivalent to: a tile number T reads bytes at `T * 128` through `T * 128 + 127`, laid out so that the four 8x8 sub-tiles occupy offsets 0..31 (top-left), 32..63 (bottom-left), 64..95 (top-right), 96..127 (bottom-right). "packed_msb" means pixel 0 is the high nibble of byte 0.

The 8x8 TX tiles are straight 32 bytes per tile, `gfx_8x8x4_packed_msb`.

### C.3 VRAM formats

**BG videoram** (`m_bgvideoram[0]`, 0x090000-0x093FFF, 8 KiB words = 8192 entries). From `nmk16_v.cpp:40-44`:
```cpp
const u16 code = m_bgvideoram[Layer][(m_tilerambank << 13) | tile_index];
tileinfo.set(Gfx, (code & 0xfff) | (m_bgbank << 12), code >> 12, 0);
```
Per-word:

| Bits | Meaning |
|---|---|
| 15..12 | Color (16 palette banks within the 256-color BG section) |
| 11..0  | Tile code (low 12 bits); effective = `code | (m_bgbank << 12)` — so total 16-bit tile index when `tilebank_w` supplies the high 4 bits |

`m_tilerambank` is 0 on hachamf (the higher bits of scroll X drive it only when BG VRAM > 16 KiB — hachamf has exactly 16 KiB, so no banking; `nmk16_v.cpp:488`).

Tilemap scan (`nmk16_v.cpp:34-37`):
```cpp
return (row & 0xf) | ((col & 0xff) << 4) | ((row & 0x10) << 8);
```
so the 256×32-tile BG arranges rows 0..15 of each of 256 columns before switching to rows 16..31 — it is effectively 4096x512 pixels arranged as 16 "pages" of 16x16 tiles each that tile horizontally.

**TX videoram** (`m_txvideoram`, 0x09C000-0x09C7FF, 2 KiB = 1024 entries):

| Bits | Meaning |
|---|---|
| 15..12 | Color (16 palette banks) |
| 11..0  | Tile code |

`TILEMAP_SCAN_COLS` → column-major 32×32. Text layer is 256×256 px logically; only top 224 rows visible.

### C.4 Scroll registers

BG layer 0 scroll, 4 bytes at 8-bit odd addresses `0x08C001, 0x08C003, 0x08C005, 0x08C007`. Handler: `scroll_w<0>` at `nmk16_v.cpp:477-501` (template instantiated at `nmk16.cpp:833`). `umask16(0x00ff)` means only the low byte of each word-write lands.

The four bytes are: `scroll[0][0..3]`.

Computation:
```cpp
if (BIT(offset, 1)) {   // offsets 2,3  (=> addr 0x08C005, 0x08C007)
    scrolly = (scroll[2] << 8) | scroll[3];     // 16-bit
} else {                // offsets 0,1  (=> addr 0x08C001, 0x08C003)
    // if BG > 16KB, high nibble of scroll[0] is tile bank (not used on hachamf)
    scrollx = (scroll[0] << 8) | scroll[1];     // 16-bit
}
```

- `0x08C001.b` = scrollx high byte (bits 15..8). Note: on boards with >16KB BG VRAM the high nibble also banks VRAM.
- `0x08C003.b` = scrollx low byte (bits 7..0).
- `0x08C005.b` = scrolly high byte.
- `0x08C007.b` = scrolly low byte.

Note the BG tilemap is shifted by `set_scrolldx(92, 92)` to align with the `videoshift=92` sprite gen — i.e. logical scroll X = 0 lines up the first visible tile at screen pixel 92. That offset must be applied in RTL rendering.

TX layer has no scroll registers (fixed position).

Tilebank (for BG 4096-tile-above banking) at `0x080019.b`, 8 bits. `tilebank_w` writes full byte to `m_bgbank` (`nmk16_v.cpp:284-293`). BG tile index = `(code & 0xFFF) | (bgbank << 12)`.

### C.5 Sprites

#### C.5.1 Sprite RAM

- Physical location: inside main RAM at `mainram + m_sprdma_base/2`. Default `m_sprdma_base = 0x8000` so sprite source lives at `0x0F8000-0x0F8FFF` (4 KiB). `nmk16.cpp:4516-4522`:
  ```cpp
  memcpy(m_spriteram_old2.get(), m_spriteram_old.get(), 0x1000);
  memcpy(m_spriteram_old.get(),  m_mainram + m_sprdma_base/2, 0x1000);
  ```
- Entry size: **16 bytes** (8 16-bit words).
- Max sprites: `4096 / 16 = 256` sprite entries.
- Double-buffered on real hardware (two copies, `spriteram_old` and `spriteram_old2`), rendered from `spriteram_old2` one frame delayed.

#### C.5.2 Sprite format

Source: `nmk16spr.cpp:17-31` and `nmk16_v.cpp:349-353`. All offsets below are *byte* offsets within the 16-byte entry; all values are 16-bit words on 68000 (big-endian).

| Offset | Bits | Meaning (hachamf / non-powerins) |
|---|---|---|
| `+0` (word 0) | `----------------s` | bit 0 = visible / enable |
| `+2` (word 1) | bits 9..8 = flipY,flipX; bits 7..4 = height tiles−1 (1..16); bits 3..0 = width tiles−1 (1..16) | sprite size + flip (from `get_sprite_flip`, bit 9 = flipy, bit 8 = flipx) |
| `+4` (word 2) | unused | — |
| `+6` (word 3) | bits 15..0 | Tile code (low 16 bits) |
| `+8` (word 4) | bits 9..0 | X position (10 bits, masked to 0..511 via `m_xmask=0x1ff`) |
| `+10` (word 5) | unused | — |
| `+12` (word 6) | bits 9..0 | Y position (9 bits masked) |
| `+14` (word 7) | bits 5..0 (4 on 4bit, 5 on 5bit) | Palette select (hachamf uses `get_colour_4bit` → mask `0xF`) |

The hachamf sprite-generator-config path:

```cpp
// nmk16.cpp:5236
m_spritegen->set_colpri_callback(FUNC(nmk16_state::get_colour_4bit));
// nmk16_v.cpp:329-333
void nmk16_state::get_colour_4bit(u32 &colour, u32 &pri_mask) {
    colour &= 0xf;
    pri_mask |= GFX_PMASK_2; // under foreground
}
```
So only the low **4 bits** of word 7 select one of 16 sprite palette sub-banks (palette `0x100-0x1FF`, i.e. 16 × 16 colors).

- The ext_callback is not set for hachamf — MAME only calls `get_sprite_flip` for manybloc. Thus on hachamf the driver reads flip bits directly (`nmk16spr.cpp:81-84`, and `set_ext_callback` unused → flipx/flipy = 0).

  Actually cross-check: `hachamf` machine_config does **not** call `set_ext_callback`. Looking at `nmk16.cpp:5227-5242` (hachamf config), indeed only `set_colpri_callback` is used. So on hachamf **sprites do not flip** (both flipx and flipy stay at 0, which matches the original game's behaviour that doesn't use sprite flipping). If RTL adds flip support using bits 8/9, it would be compatible with manybloc but it does not match hachamf's native software behaviour (which is why the driver doesn't enable it).

#### C.5.3 Sprite size & multi-tile

Each sprite draws a rectangle `(w+1) × (h+1)` tiles where w/h come from word 1 bits 3..0/7..4 (values 0..15 → 1..16 tile dimensions). Tile codes step sequentially: for each row, `code += (w+1)` between rows; columns increment by 1 from the base code. So code `T` with size 2x2 spans `T, T+1, T+2, T+3` in a row-major order of *tile indices* (= 16x16 tiles).

#### C.5.4 Screen positioning

- X/Y position is in **pixels**, modulo 512 (or modulo 1024 on 10-bit position — see `xmask=0x1ff` default for low-res; `ymask=0x1ff`). The driver adds `videoshift=92` for low-res (`nmk16.cpp:4361`).
- Wrapping: if `x > cliprect.max_x`, the generator subtracts `xpos_max=512` for wraparound (`nmk16spr.cpp:135`).

#### C.5.5 Max sprite clock

`m_max_sprite_clock = 384 * 263` = 101,952 clocks (low-res per hardware manual). Each sprite consumes `16 + 128 * w_tiles * h_tiles` clocks. This is the hardware's per-frame sprite render budget — if exhausted before the sprite list ends, remaining sprites are not rendered (`nmk16spr.cpp:60-88`).

#### C.5.6 Sprite priority / mixing

Single priority tier on hachamf: `GFX_PMASK_2` means sprites are drawn *under the TX layer*, above the BG layer. Mixing order (`nmk16_v.cpp:420-427`, `screen_update_macross`):

```cpp
screen.priority().fill(0, cliprect);
bg_update(screen, bitmap, cliprect, 0);    // BG layer 0 (opaque)
tx_update(screen, bitmap, cliprect);       // TX layer (transparent on pen 15, priority=2)
draw_sprites(screen, bitmap, cliprect, m_spriteram_old2.get()); // priority-aware
```

Effective per-pixel priority (bottom to top):
1. BG (opaque, fills background).
2. Sprites (except where TX layer wrote a `pri=2` pixel, sprites go under).
3. TX layer (opaque non-15 pens).

Translation for RTL: sprites compare `pri_mask | 2` vs priority buffer; TX layer writes opaque pixels with `priority=2`; sprites with `pri_mask & 2` are suppressed where TX wrote opaque. Since all sprites get `pri_mask = 2`, sprites **never appear on top of TX** on hachamf — TX is always the topmost visible layer.

### C.6 Sprite DMA

On sprite-DMA trigger (V-timing PROM bit 0 rising edge — typically 2 lines after VBOUT, ~line 242) the hardware does two 4 KiB copies (`nmk16.cpp:4516-4522`):

```cpp
void nmk16_state::sprite_dma() {
    memcpy(m_spriteram_old2.get(), m_spriteram_old.get(), 0x1000);
    memcpy(m_spriteram_old.get(),  m_mainram + m_sprdma_base/2, 0x1000);
    // m_maincpu->spin_until_time(attotime::from_usec(694)); // 68000 stopped during DMA
}
```
Duration on real hardware: **694 µs** (per driver comment at `nmk16.cpp:4463-4470`). CPU is stalled.

RTL recommendation: implement as two 2 KiB-word block copies from mainram `$F8000..$F8FFF` into two internal 2KB-word double buffers; freeze 68000 BUSREQ for ~694 µs while doing so; rendering reads from the *oldest* buffer (two-frame pipeline, matching MAME).

### C.7 Palette

- RAM address `0x088000-0x0887FF` = 2048 bytes = 1024 entries × 16 bits.
- MAME palette format: `palette_device::RRRRGGGGBBBBRGBx` (`nmk16.cpp:5240`). 16 colors × 1024 palette = 1024 entries.

Decode of a 16-bit palette word → 5-bit-per-channel RGB (one extended LSB per channel from the low nibble):

```
word bits : R3 R2 R1 R0 G3 G2 G1 G0 B3 B2 B1 B0 R_ext G_ext B_ext x
             15 14 13 12 11 10  9  8  7  6  5  4   3    2    1   0

R5bit = {R3,R2,R1,R0,R_ext}
G5bit = {G3,G2,G1,G0,G_ext}
B5bit = {B3,B2,B1,B0,B_ext}
```

Bit 0 is unused. (In practice NMK16 board palette DAC is 4-bit per channel, so using just R3..R0 / G3..G0 / B3..B0 and zeroing the low extension bit is also faithful. MAME's `RRRRGGGGBBBBRGBx` format uses the low nibble of the word as LSB extension, giving 5 bits per channel.)

**Palette layout** (based on gfxdecode base offsets `nmk16.cpp:4186-4190`):
- `0x000-0x0FF`: BG tiles (16 banks × 16 colors).
- `0x100-0x1FF`: Sprites (16 banks × 16 colors).
- `0x200-0x2FF`: TX/FG tiles (16 banks × 16 colors).
- `0x300-0x3FF`: unused on hachamf.

Palette RAM is written little-endian-in-word as usual for 68000: upper byte is D15..D8, etc.

### C.8 GFX ROM organization

Three separate GFX ROM regions (`nmk16.cpp:7915-7922`):

- **`fgtile`** (TX layer): 1 × 128 KiB — tile format `gfx_8x8x4_packed_msb`. Linear: 32 bytes/tile × 4096 tiles = 128 KiB. Byte order: each byte encodes 2 pixels, MSB first (pixel N has bits 7..4 of byte N/2 when N even else bits 3..0). Reads one byte per row-pair internally (row 0 pixels 0/1 in byte 0, pixels 2/3 in byte 1, ...). Hachamf ROM: `5.95` CRC `29fb04a2`.
- **`bgtile`** (BG layer): 1 × 1 MiB — format `gfx_8x8x4_col_2x2_group_packed_msb`. 128 bytes/16x16 tile × 8192 = 1 MiB. Hachamf ROM: `91076-4.101` CRC `df9653a4`.
- **`sprites`**: 1 × 1 MiB — same packing as bgtile (`col_2x2_group_packed_msb` 16x16 tile). Loaded with `ROM_LOAD16_WORD_SWAP` — that means the ROM is 16-bit-word-swapped from 68000-byte-order, so on the FPGA load image you'll need to swap pairs of bytes if coming from the "raw" MAME ROM. Hachamf ROM: `91076-8.57` CRC `7fd0f556`. 8192 sprite tiles total.

---

## D. Audio

Per `hachamf(machine_config)` at `nmk16.cpp:5227-5263`:

### D.1 Chips

| Chip | Role | Clock | Source line |
|---|---|---|---|
| **NMK004** (TMP90C840 + 8K int ROM) | Sound coprocessor: runs sequence / driver code, latches from main CPU, sends commands to YM and OKIs | 8 MHz | `nmk16.cpp:5246` |
| **YM2203** | FM + PSG (3×FM, 3×SSG) | 1.5 MHz | `nmk16.cpp:5249` |
| **OKIM6295 #1 (oki1)** | ADPCM samples | 16 MHz / 4 = 4 MHz, PIN7 LOW (sample rate divider 132 → ~7575 Hz) | `nmk16.cpp:5256-5258` |
| **OKIM6295 #2 (oki2)** | ADPCM samples | 16 MHz / 4 = 4 MHz, PIN7 LOW | `nmk16.cpp:5260-5262` |

Mixing levels (MAME values — relative): YM2203 chan0=0.5, chan1=0.5, chan2=0.5, chan3 (sum/FM)=1.2; both OKIs at 0.1.

### D.2 Sample ROM layout & banking

OKI memory maps (`nmk16.cpp:1237-1247`):

```cpp
void nmk16_state::oki1_map(address_map &map) {
    map(0x00000, 0x1ffff).rom().region("oki1", 0);
    map(0x20000, 0x3ffff).bankr(m_okibank[0]);
}
void nmk16_state::oki2_map(address_map &map) {
    map(0x00000, 0x1ffff).rom().region("oki2", 0);
    map(0x20000, 0x3ffff).bankr(m_okibank[1]);
}
```

Each OKI has:
- Fixed low 128 KiB at OKI-bus `0x00000..0x1FFFF` (= the first 128 KiB of the `okiN` ROM region).
- Windowed 128 KiB at OKI-bus `0x20000..0x3FFFF` switchable between 4 banks.

Bank configuration from NMK004 code (`nmk004.cpp:58-63, 130-133`):
```cpp
for (int i = 0; i < 2; i++) {
    m_okibank[i]->configure_entries(0, 4, m_okirom[i] + 0x20000, 0x20000);
}
template <unsigned Which>
void nmk004_device::oki_bankswitch_w(uint8_t data) {
    data &= 3;
    m_okibank[Which]->set_entry(data);
}
```

So each 512 KiB OKI sample ROM (`91076-2.46` / `91076-3.45`) is split:
- First 128 KiB (`0x00000-0x1FFFF`): fixed at OKI addr `0x00000-0x1FFFF`.
- Remaining 384 KiB: laid out as 3 × 128 KiB banks **starting at ROM offset 0x20000**:
  - Bank 0 → ROM `0x20000..0x3FFFF`
  - Bank 1 → ROM `0x40000..0x5FFFF`
  - Bank 2 → ROM `0x60000..0x7FFFF`
  - Bank 3 → ROM `0x80000..0x9FFFF` *(but ROMs are only 0x80000 = 512 KiB; NMK004 code `0..3` means 4 banks, but only banks 0..2 are valid within 512 KiB — the hachamf ROMs happen to have duplicate halves anyway: comment `nmk16.cpp:7925` "1st & 2nd half identical").*

Bank selection:
- OKI #0 bank: NMK004 writes to its internal address `0xFC01` (`nmk004.cpp:93`).
- OKI #1 bank: NMK004 writes to its internal address `0xFC02` (`nmk004.cpp:94`).
Both are 2-bit values (0..3).

### D.3 Sample triggering

- 68000 cannot directly write to OKI. It writes an 8-bit command to latch `0x08001F`; NMK004 MCU reads it at `0xFB00`, interprets (uses its external sound-data ROM `1.70`), and issues OKI commands at `0xF900/0xFA00`.
- The NMK004 also drives YM2203 via `0xF800/0xF801`.
- YM2203's timer IRQ feeds the NMK004's external INT0 (`nmk16.cpp:5250` `ymsnd.irq_handler().set("nmk004", FUNC(nmk004_device::ym2203_irq_handler))`). NMK004 sets input line 0 (`nmk004.cpp:78-81`).

### D.4 hachamf specifics

- NMK004 external program ROM: `1.70` 64 KiB CRC `9e6f48fc` (`nmk16.cpp:7913`).
- Two OKI sample ROMs of 512 KiB each.
- Both the parent `hachamf` and bootleg `hachamfb` share identical sample ROMs (91076-2.46 / 91076-3.45).
- The `hachamfb2` bootleg replaces the entire NMK004+YM2203+2xOKI chain with a Seibu-Raiden sound board (Z80 + YM3812 + 1×OKI) — *do not* implement this path in the parent core.

---

## E. Protection / MCU

### E.1 NMK-113 on hachamf (parent set)

- **Role**: The NMK-113 is a protection MCU that on hachamf (parent) **must be present** — the game patches/initializes some mainram addresses at boot via bus-mastering the 68000 bus. The bootleg `hachamfb` has the protection removed from the 68000 code.
- **Chip**: Toshiba **TMP91640** (TLCS-900 16-bit MCU), 16 KiB internal ROM, 512 bytes internal RAM. `nmk16.cpp:5269`:
  ```cpp
  TMP91640(config, m_protcpu, 4000000); // Toshiba TMP91640 marked as NMK-113
  ```
- **Clock**: 4 MHz.
- **Internal ROM**: `nmk-113.bin`, 16 KiB, CRC `f3072715`, SHA1 `cee6534de6645c41cbbb1450ad3e5207e44460c7` (`nmk16.cpp:7910`).
- **Mechanism**:
  - The NMK-113 address space maps `0x000000-0x0FFFFF` of the *68000* memory space (same memory). `tdragon_prot_map` at `nmk16.cpp:5104-5108`.
  - MCU port 6 in = bus-arbitration handshake register (MAME simulates: read returns toggling bit 2).
  - MCU port 6 out = `0x08` asserts 68000 HALT (bus takeover), `0x0B` releases HALT. `nmk16.cpp:5018-5036`.
  - MCU port 5 in = `screen->vpos() >> 2` (a timing reference, low 6 bits of vertical position).
  - MCU port 7 in = hardwired config select. For hachamf, MAME hardwires **`0x0C`** (`nmk16.cpp:5298`) to select the "Hacha Mecha Fighter" codepath inside the shared nmk-113 firmware. The same nmk-113 firmware handles multiple games:
    ```
    // 0x0c - Hacha Mecha Fighter
    // 0x0e - Double Dealer
    // 0x0f - Thunder Dragon
    ```
- **What the MCU actually does (observed)**: Periodically wakes up, HALTs 68000, reads/writes specific main-RAM words (game tables / scores / initial state), releases the bus. No fixed "challenge/response" port. It's effectively a DMA master that mutates mainram based on its own internal tables.

### E.2 MAME emulation approach

MAME runs the real NMK-113 internal ROM (`nmk-113.bin`) with **actual TMP91640 CPU emulation**, not an HLE simulation. `tdragon_prot_state::mcu_port6_w` implements the HALT gate, but the actual protection logic comes from running the MCU code. For RTL, you have two options:

1. **High-level simulation (HLE)**: reverse-engineer the NMK-113 behaviour for hachamf (config `0x0C`) and patch the required mainram locations directly. The bootleg `hachamfb` contains the game running *without* NMK-113 — comparing `hachamf` vs `hachamfb` 68000 ROMs reveals exactly which instructions the MCU replaces (typical approach used by MAME when MCU dump is unavailable).
2. **Bus-arbiter + soft TLCS-900 core**: ship the `nmk-113.bin` as a ROM blob alongside the core and emulate TMP91640 in FPGA (~4 MHz TLCS-900 core). Heavier, but faithful.

MAME's comment at `nmk16.cpp:61` notes: "Protection is patched in several games" — historically for Thunder Dragon/hachamf, MAME used to patch 68000 ROM too.

### E.3 Protection reads/writes seen by main 68000

**None visible on the 68000 bus itself** (the NMK-113 talks through its own bus master path). The game code does *no* port-I/O to the MCU. The only thing the main CPU does is share its mainram at `0x0F0000-0x0FFFFF` with the MCU, and the MCU writes values there that the 68000 subsequently reads.

---

## F. ROM set (hachamf parent + clones)

Reference: `ROM_START(hachamf)` `nmk16.cpp:7903-7937` and clone sets.

### F.1 hachamf (parent) — matches files in `roms/hachamf/`

| File (user) | MAME name | Size | CRC32 | Region / role | MAME address |
|---|---|---|---|---|---|
| `7.93` | `7.93` | 128 KiB | `9d847c31` | 68000 code (even) | `maincpu 0x00000`, loaded via `ROM_LOAD16_BYTE` → fills D15..D8 of addresses 0x00000-0x3FFFE (even bytes) |
| `6.94` | `6.94` | 128 KiB | `de6408a0` | 68000 code (odd) | `maincpu 0x00001`, fills D7..D0 of 0x00001-0x3FFFF (odd bytes) |
| `nmk-113.bin` | `nmk-113.bin` | 16 KiB | `f3072715` | NMK-113 TMP91640 internal ROM | `protcpu 0x0000-0x3FFF` |
| `1.70` | `1.70` | 64 KiB | `9e6f48fc` | NMK004 external program ROM (TLCS-90) | `nmk004 0x0000-0xFFFF` (effective `0x2000-0xEFFF` after internal ROM overlay) |
| `5.95` | `5.95` | 128 KiB | `29fb04a2` | TX/FG 8x8 tiles (4bpp) | `fgtile 0x00000-0x1FFFF` |
| `91076-4.101` | `91076-4.101` | 1 MiB | `df9653a4` | BG 16x16 tiles (4bpp, col_2x2_group) | `bgtile 0x00000-0xFFFFF` |
| `91076-8.57` | `91076-8.57` | 1 MiB | `7fd0f556` | Sprites (4bpp, col_2x2_group, WORD_SWAP) | `sprites 0x00000-0xFFFFF` — **loaded with `ROM_LOAD16_WORD_SWAP`** — byte-swap every 2 bytes relative to "raw" ROM when feeding FPGA |
| `91076-2.46` | `91076-2.46` | 512 KiB | `3f1e67f2` | OKI1 samples (1st/2nd half identical per comment) | `oki1 0x00000-0x7FFFF` |
| `91076-3.45` | `91076-3.45` | 512 KiB | `b25ed93b` | OKI2 samples (1st/2nd half identical per comment) | `oki2 0x00000-0x7FFFF` |
| `82s129.ic51` | `82s129.ic51` | 256 B | `cfdbb86c` (BAD_DUMP on hachamf — dump taken from hachamfp) | H-timing PROM (horizontal timing; optional for RTL) | `nmk_irq:htiming 0x00-0xFF` |
| `82s135.ic50` | `82s135.ic50` | 256 B | `633ab1c9` (BAD_DUMP; same source) | V-timing PROM → IRQ/DMA schedule | `nmk_irq:vtiming 0x00-0xFF` |

Total footprint used on core: ~3.27 MiB of ROM data (ignoring PROMs & MCU blobs).

### F.2 hachamfa clone

`nmk16.cpp:7939-7973`. Different 68000 EPROMs and different FG tiles (different splash screen/logo). Shares everything else with parent.

Files in `roms/hachamf/hachamfa/`:

| File | MAME name | CRC | Role |
|---|---|---|---|
| `7.ic93` | `7.ic93` | `f437e52b` | 68000 even |
| `6.ic94` | `6.ic94` | `60d340d0` | 68000 odd |
| `5.ic95` | `5.ic95` | `a2c1e25d` | FG 8x8 tiles (Korean logo variant) |

Also uses parent's `nmk-113.bin`, `1.70`, `91076-4.101`, `91076-8.57`, `91076-2.46`, `91076-3.45`, `82s129.ic51`, `82s135.ic50`.

### F.3 hachamfb clone (unprotected Thunder Dragon conversion bootleg)

`nmk16.cpp:7975-8005`. **No NMK-113** — uses MAME's base `hachamf` config (no prot).

Files in `roms/hachamf/hachamfb/`:

| File | MAME name | CRC | Role |
|---|---|---|---|
| `8.bin` | `8.bin` | `14845b65` | 68000 even |
| `7.bin` | `7.bin` | `069ca579` | 68000 odd |

Everything else from parent. This set is interesting for FPGA: it's the "as-shipped without protection" reference — boots without needing the NMK-113.

### F.4 hachamfp clone (prototype)

`nmk16.cpp:8007-8037`. Uses separate BG and sprite ROMs (not yet consolidated into the mask ROMs). No NMK-113 prot.

Files in `roms/hachamf/hachamfp/`:

| File | MAME name | CRC | Role |
|---|---|---|---|
| `kf-68-pe-b.ic7` | `kf-68-pe-b.ic7` | `b98a525e` | 68000 even |
| `kf-68-po-b.ic6` | `kf-68-po-b.ic6` | `b62ad179` | 68000 odd |
| `kf-snd.ic4` | `kf-snd.ic4` | `f7cace47` | NMK004 external program ROM |
| `kf-vram.ic3` | *(not in your listing but same as 5.ic95/CRC a2c1e25d)* | `a2c1e25d` | FG 8x8 tiles |
| `kf-scl0.ic5` | `kf-scl0.ic5` | `8604adff` | BG tiles low half (512 KiB) |
| `kf-scl1.ic12` | `kf-scl1.ic12` | `05a624e3` | BG tiles high half (512 KiB) |
| `kf-obj0.ic8` | `kf-obj0.ic8` | `a471bbd8` | Sprites even bytes (ROM_LOAD16_BYTE, 512 KiB) |
| `kf-obj1.ic11` | `kf-obj1.ic11` | `81594aad` | Sprites odd bytes |
| `kf-a0.ic2` | `kf-a0.ic2` | `e068d2cf` | OKI1 samples |
| `kf-a1.ic1` | `kf-a1.ic1` | `d945aabb` | OKI2 samples |

Note sprite loading in hachamfp uses `ROM_LOAD16_BYTE` (interleave), not `ROM_LOAD16_WORD_SWAP`, so byte ordering relative to the FPGA differs from parent. To produce a unified FPGA image from either set, the RTL should treat sprite ROM as 16-bit words where D15..D8 = even ROM, D7..D0 = odd ROM (hachamfp) or equivalent after un-swap (hachamf). The final *in-FPGA* byte order must match one of the two.

### F.5 hachamfb2 clone (Raiden-sound bootleg)

`nmk16.cpp:7254-7278`. Different PCB (acrobatmbl-based), different sound hardware (Z80 + YM3812 + single OKI). Not recommended to support in the NMK16 core — it belongs to a different hardware family.

Files in `roms/hachamf/hachamfb2/`:

| File | Role |
|---|---|
| `1.14y` | Single OKIM6295 samples (64 KiB) |
| `2.12w` | Z80 audio CPU (32 KiB with banking) |
| `10c`, `10e` | 68000 program (128 KiB each) |
| `b.2k`, `c.2m` | Sprites (1 MiB each, MAME ignores 2nd half as 1st/2nd identical) |

---

## G. Screen origin & "92 pixel shift" gotcha

All rendering is shifted by 92 pixels on low-res:
- Sprite generator: `set_videoshift(92)` means sprite X coordinate 0 renders at screen pixel 92. `nmk16.cpp:4361`.
- BG tilemap: `set_scrolldx(92, 92)` — scroll X 0 puts the first tile at screen pixel 92. `nmk16_v.cpp:133-137`.
- TX tilemap: same 92 pixel offset.

Visible area is pixels 92..347 (256 px wide), matching `set_raw(..., 384, 92, 348, ...)` at `nmk16.cpp:4355`.

So when implementing rendering, **your active video window starts 92 px after HSYNC de-asserts**, and coordinates from sprite RAM / scroll registers are relative to this origin (not to HSYNC).

---

## H. Top-level block diagram (for RTL)

```
                   +---------------------------+
                   |         Main 68000        |
                   |     (10 MHz, BE, 24-bit)  |
                   +---+-----+-----+-----+----+
                       |     |     |     |    \ HALT/BG
              [ROM]    |     |     |     |     \
    4 MiB mapped   prog ROM  VRAM  WRAM  I/O    +------ NMK-113 MCU
    (even+odd)    256 KiB   18 KiB 64 KiB        (TMP91640, 4 MHz,
                                                  16 KiB int ROM)
                       |     |     |     |
                       v     v     v     v
                   +---------------------------+
                   |   NMK016 VIDEO + IRQ      |
                   |  - BG tilemap 256x32      |
                   |  - TX tilemap  32x32      |
                   |  - Sprite DMA (256 ents)  |
                   |  - Palette 1024 x 16 bit  |
                   |  - 82S129 H-timing PROM   |
                   |  - 82S135 V-timing PROM   |
                   |    -> IRQ1/IRQ2/IRQ4, DMA |
                   +------------+--------------+
                                |
                              Video out (6 MHz pxclk, 256x224@56Hz)

  Main <-> NMK004 latches:
     W 0x08001F  ->  NMK004 0xFB00
     R 0x08000F  <-  NMK004 0xFC00
     W 0x080016.b0 -> NMK004 NMI (watchdog)
     NMK004 port4.b0 -> 68000 RESET

                   +---------------------------+
                   |     NMK004 sound coproc   |
                   | (TMP90C840, 8 MHz int ROM |
                   |     8 KiB "V-00" 900315)  |
                   |  + ext ROM "1.70" 64 KiB  |
                   +---+-----+-----+-----------+
                       |     |     |
                  YM2203   OKI1   OKI2
                 (1.5 MHz) (4 MHz) (4 MHz)
                           +bank   +bank
                           (2b)    (2b)
```

---

## I. Existing FPGA precedents

Searched (April 2026); no public open-source NMK16 core could be confirmed:
- <https://github.com/jotego/jtcores> — Jotego (Jose Tejada) has many NMK-era cores but **not NMK16**. His catalogue covers System 16, Capcom, Seibu, etc. No jtnmk16.
- <https://github.com/MiSTer-devel> — no existing `Arcade-NMK*` core. See <https://mister-devel.github.io/MkDocs_MiSTer/cores/arcade/>.
- Furrtek has unrelated work (CPS, NeoGeo). Nothing NMK16.
- NMK16 emulation work appears confined to MAME (`nmk/nmk16.cpp` driver by Buffoni/Salmoria/McPhail/Haywood/Belmont/Marshall/Salese/Elia). There have been driver cleanups in the MAME2003-libretro fork but nothing RTL.

**Closest useful reference RTL**: generic 68000 cores (TG68, fx68k), generic YM2203 (JT03 from Jotego), generic MSM6295/OKI6295 (JT6295). These are drop-in for the sound subsystem. The NMK004 TLCS-90 core has to be built (or HLE'd) from scratch — there's no existing open-source TLCS-90 core suitable for FPGA, but MAME's `cpu/tlcs90/` is a reference. For the NMK-113 (TLCS-900), similarly no FPGA core exists.

Practical path: **use real NMK004 internal ROM + a soft TLCS-90 core** (doable — TLCS-90 is 8-bit, Z80-ish, 150ish opcodes). **HLE the NMK-113** (as hachamfb shows the game works without it if you patch mainram correctly) — or support only `hachamfb`/`hachamfp` for v1.

---

## J. Minimum viable core (suggested staging)

1. **Phase 1 — `hachamfp` or `hachamfb`** (no NMK-113): 68000 + video + latched sound stub. No protection. Verifies BG/TX/sprite/palette pipeline.
2. **Phase 2 — NMK004 real**: TLCS-90 soft core + YM2203 + 2× OKIM6295 with bank windows.
3. **Phase 3 — NMK-113**: TLCS-900 soft core + bus arbitration (or HLE equivalent), completing parent `hachamf`.
4. **Phase 4 — other NMK16 games** (Macross, Thunder Dragon, Mustang, Black Heart, Vandyke, Acrobat Mission, Strahl, Bio-ship Paladin): same skeleton with per-game address-map selection and NMK-21x protection variants.

---

## K. Key MAME source files to keep handy

- `src/mame/nmk/nmk16.cpp` — driver, all memory maps, ROM sets, machine configs, DIPs.
- `src/mame/nmk/nmk16.h` — state classes (`nmk16_state`, `tdragon_prot_state`, etc.).
- `src/mame/nmk/nmk16_v.cpp` — video init, tilemap callbacks, priority mixing.
- `src/mame/nmk/nmk16spr.cpp` / `nmk16spr.h` — sprite generator (authoritative sprite format, clock budget).
- `src/mame/nmk/nmk_irq.cpp` / `nmk_irq.h` — V-timing PROM, IRQ/DMA scheduler.
- `src/mame/nmk/nmk004.cpp` / `nmk004.h` — NMK004 sound coprocessor (TLCS-90 MCU device).
- `src/mame/nmk/nmk214.cpp` / `nmk214.h` — NMK-214/215 (**not used by hachamf** — only macross/gunnail etc.).

---

## L. Glossary / quick facts

| Term | Value |
|---|---|
| Main CPU | MC68000, 10 MHz, big-endian |
| Main ROM | 256 KiB (2 × 128 KiB interleaved) at `0x000000-0x03FFFF` |
| Main RAM | 64 KiB at `0x0F0000-0x0FFFFF`, shared with NMK-113 |
| BG VRAM | 16 KiB at `0x090000-0x093FFF`, 16x16 tiles, 256x32 tilemap, 4bpp |
| TX VRAM | 2 KiB at `0x09C000-0x09C7FF`, 8x8 tiles, 32x32 tilemap, 4bpp |
| Palette RAM | 2 KiB at `0x088000-0x0887FF`, 1024 × RGB444 (with +1 bit extension) |
| Sprite RAM | 4 KiB inside mainram at `0x0F8000-0x0F8FFF`, 256 × 16 B |
| Scroll regs | 4 bytes at odd offsets `0x08C001/3/5/7` |
| Flipscreen reg | `0x080015.b0` |
| BG tile bank | `0x080019.b` (8 bits) |
| Sound latch tx | `0x08001F.b` → NMK004 |
| Sound latch rx | `0x08000F.b` ← NMK004 |
| NMK004 NMI / watchdog | `0x080016.b0` |
| IRQ1 | Mid-screen (scanlines 68 & 196) |
| IRQ2 | VBIN (scanline 16) |
| IRQ4 | VBOUT (scanline 240) |
| Sprite DMA | Scanline ~242 (2 lines after VBOUT), copies 4 KiB, 694 µs, CPU halted |
| Screen | 256×224 visible, 384×278 total, 6 MHz pxclk, 56.2 Hz |
| Sound | NMK004 (TMP90C840 @ 8 MHz) + YM2203 @ 1.5 MHz + 2× OKIM6295 @ 4 MHz |
| Protection | NMK-113 (TMP91640 @ 4 MHz, 16 KiB int ROM) as bus-master DMA slave |

---

## Source citations

All line numbers reference <https://github.com/mamedev/mame/tree/master/src/mame/nmk> at HEAD as of fetch (April 2026).

- Address map: `nmk16.cpp:818-837`
- `hachamf` machine_config: `nmk16.cpp:5227-5263`
- `hachamf_prot` machine_config (adds NMK-113): `nmk16.cpp:5265-5301`
- IN0/IN1/DSW1/DSW2 port definitions: `nmk16.cpp:1848-1926`
- ROM_START(hachamf): `nmk16.cpp:7903-7937`
- ROM_START(hachamfa): `nmk16.cpp:7939-7973`
- ROM_START(hachamfb): `nmk16.cpp:7975-8005`
- ROM_START(hachamfp): `nmk16.cpp:8007-8037`
- ROM_START(hachamfb2): `nmk16.cpp:7254-7278`
- Driver game entry: `nmk16.cpp:10697`
- NMK004 memory map: `nmk004.cpp:83-95`
- NMK004 internal ROM: `nmk004.cpp:98-101`
- NMK004 watchdog/reset: `nmk16.cpp:224-230`, `nmk004.cpp:28-34`
- IRQ scheduler: `nmk_irq.cpp:211-252`, `nmk16.cpp:4436-4445`
- V-timing PROM format: `nmk_irq.cpp:80-89`
- H-timing PROM format: `nmk_irq.cpp:32-39`
- Screen params (low-res): `nmk16.cpp:4352-4362`
- Sprite DMA: `nmk16.cpp:4516-4522`
- Sprite format: `nmk16spr.cpp:15-31`
- Sprite draw implementation: `nmk16spr.cpp:53-256`
- Video priority mixing: `nmk16_v.cpp:420-427`
- Tilemap mapping: `nmk16_v.cpp:34-37`
- BG tile code format: `nmk16_v.cpp:39-44`
- TX tile code format: `nmk16_v.cpp:46-50`
- Scroll register decoder: `nmk16_v.cpp:477-501`
- Tilebank: `nmk16_v.cpp:284-293`
- Flipscreen: `nmk16_v.cpp:272-275`
- GFXDECODE (macross = hachamf): `nmk16.cpp:4186-4190`
- OKI memory map + banking: `nmk16.cpp:1237-1247`, `nmk004.cpp:58-63, 130-133`
- NMK-113 (TMP91640) config: `nmk16.cpp:5265-5301`, port-7 game-select comment `nmk16.cpp:5275-5298`
- MCU bus takeover protocol: `nmk16.cpp:5018-5036, 5038-5049`

