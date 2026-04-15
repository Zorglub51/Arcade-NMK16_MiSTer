#!/usr/bin/env python3
# Build Verilog $readmemh-friendly hex images for the hachamfb sim:
#   roms/hachamfb_prog.hex   128 Ki big-endian words (256 KiB main ROM)
#   roms/hachamf_bg.hex      1 Mi  bytes (BG GFX, 91076-4.101)
#   roms/hachamf_tx.hex      128 Ki bytes (TX GFX, 5.95)
# All inputs CRC-checked against MAME nmk16.cpp.

import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ROM_HACHAMFB = ROOT / 'roms' / 'hachamf' / 'hachamfb'
ROM_HACHAMF  = ROOT / 'roms' / 'hachamf'
DST_DIR      = ROOT / 'roms'

def write_words_be(out_path, even_bytes, odd_bytes):
    """Interleave even+odd byte arrays into BE words, one per line (hex)."""
    n = len(even_bytes)
    assert n == len(odd_bytes)
    with out_path.open('w') as f:
        for i in range(n):
            f.write(f'{(even_bytes[i] << 8) | odd_bytes[i]:04x}\n')

def write_words_be_bin(out_path, even_bytes, odd_bytes):
    """Interleave even+odd byte arrays into BE raw bytes."""
    n = len(even_bytes)
    assert n == len(odd_bytes)
    buf = bytearray(n * 2)
    for i in range(n):
        buf[2*i    ] = even_bytes[i]   # high byte first (big-endian)
        buf[2*i + 1] = odd_bytes[i]
    out_path.write_bytes(bytes(buf))

def write_bytes(out_path, data):
    """One byte per line (hex)."""
    with out_path.open('w') as f:
        for b in data:
            f.write(f'{b:02x}\n')

def write_bytes_bin(out_path, data):
    """Raw binary — 1 byte per byte, no formatting."""
    out_path.write_bytes(bytes(data))

def load_check(path, expected_crc, expected_size):
    data = path.read_bytes()
    assert len(data) == expected_size, f'{path.name} size {len(data)} != {expected_size}'
    crc = zlib.crc32(data)
    assert crc == expected_crc, f'{path.name} CRC {crc:08x} != {expected_crc:08x}'
    return data

DST_DIR.mkdir(parents=True, exist_ok=True)

# ----- Main ROM (hachamfb program) -----
even = load_check(ROM_HACHAMFB / '8.bin', 0x14845b65, 0x20000)   # D15..D8
odd  = load_check(ROM_HACHAMFB / '7.bin', 0x069ca579, 0x20000)   # D7..D0
prog = DST_DIR / 'hachamfb_prog.hex'
write_words_be(prog, even, odd)
print(f'wrote {prog}  (256 KiB program hex)')
prog_bin = DST_DIR / 'hachamfb_prog.bin'
write_words_be_bin(prog_bin, even, odd)
print(f'wrote {prog_bin}  (256 KiB program binary)')
print(f'  reset SSP  = {(even[0]<<24)|(odd[0]<<16)|(even[1]<<8)|odd[1]:08x}')
print(f'  reset PC   = {(even[2]<<24)|(odd[2]<<16)|(even[3]<<8)|odd[3]:08x}')

# ----- BG GFX (16x16 4bpp col_2x2_group_packed_msb) -----
bg = load_check(ROM_HACHAMF / '91076-4.101', 0xdf9653a4, 0x100000)
bg_path = DST_DIR / 'hachamf_bg.hex'
write_bytes(bg_path, bg)
print(f'wrote {bg_path}  (1 MiB BG GFX hex)')
bg_bin = DST_DIR / 'hachamf_bg.bin'
write_bytes_bin(bg_bin, bg)
print(f'wrote {bg_bin}  (1 MiB BG GFX bin)')

# ----- TX GFX (8x8 4bpp packed_msb) -----
tx = load_check(ROM_HACHAMF / '5.95', 0x29fb04a2, 0x20000)
tx_path = DST_DIR / 'hachamf_tx.hex'
write_bytes(tx_path, tx)
print(f'wrote {tx_path}  (128 KiB TX GFX hex)')
tx_bin = DST_DIR / 'hachamf_tx.bin'
write_bytes_bin(tx_bin, tx)
print(f'wrote {tx_bin}  (128 KiB TX GFX bin)')

# ----- Sprite GFX (16x16 4bpp col_2x2_group_packed_msb, ROM_LOAD16_WORD_SWAP) -----
# MAME uses ROM_LOAD16_WORD_SWAP which byte-swaps each 16-bit word on load.
# Raw file bytes [A,B,C,D,...] become memory bytes [B,A,D,C,...].
spr_raw = load_check(ROM_HACHAMF / '91076-8.57', 0x7fd0f556, 0x100000)
spr = bytearray(spr_raw)
for i in range(0, len(spr), 2):
    spr[i], spr[i+1] = spr[i+1], spr[i]
spr_path = DST_DIR / 'hachamf_spr.hex'
write_bytes(spr_path, bytes(spr))
print(f'wrote {spr_path}  (1 MiB sprite GFX hex, byte-pair swapped)')
spr_bin = DST_DIR / 'hachamf_spr.bin'
write_bytes_bin(spr_bin, bytes(spr))
print(f'wrote {spr_bin}  (1 MiB sprite GFX bin, byte-pair swapped)')
