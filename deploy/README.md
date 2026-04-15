# NMK16 MiSTer core — delivery package

Everything needed to put Hacha Mecha Fighter (`hachamfb`) on a MiSTer DE10-Nano.

```
deploy/
├── source/    ← for you: compile NMK16.rbf from these sources with Quartus
└── release/   ← for your tester/end-users: drop-in package, no tools needed
```

## Workflow

```
  (you, with Quartus)                (tester, just a MiSTer)
┌────────────────────┐             ┌────────────────────────────┐
│ source/            │             │ release/                   │
│  NMK16.sv, rtl/,   │    build    │  NMK16_YYYYMMDD.rbf  ←─────┼── you add this
│  sys/, .qsf, ...   │ ──────────▶ │  hachamfb.mra              │
│                    │             │  END_USER_README.md        │
└────────────────────┘             └──────────┬─────────────────┘
                                              │ zip + hand to tester
                                              ▼
                                    copy to MiSTer SD,
                                    play, report back
```

## Step by step

### Step 1 — you build the `.rbf`

See [`source/README.md`](source/README.md) and [`source/QUICKSTART.md`](source/QUICKSTART.md).

Summary: install Quartus Prime Lite 17.0, run `quartus_sh --flow compile NMK16` from the `source/` folder, copy the resulting `output_files/NMK16.rbf` into `release/`, rename it `NMK16_YYYYMMDD.rbf`.

### Step 2 — you hand `release/` to your tester

Your tester needs **no tools**. They drop the folder contents on their MiSTer SD card and play. Full instructions for them: [`release/END_USER_README.md`](release/END_USER_README.md).

### Step 3 — tester reports back

The end-user README has a short "Testing feedback" section with what to look for. Tester fills it in and sends it to you. Since v1 is a smoke-test build, you don't expect to see real graphics yet — just confirmation that the bitstream loads, CPU runs, and controls reach the game.

## What is Quartus and do I (you) really need it?

**Quartus Prime Lite** = Intel/Altera's FPGA design software. Free ~20 GB download from <https://www.intel.com/content/www/us/en/software/programmable/quartus-prime/download.html>. Pin to **version 17.0 or 17.1** — the MiSTer framework's IP cores assume that generation.

You need it because it's the only tool that can turn our SystemVerilog source into the `.rbf` bitstream the FPGA chip loads. Nobody else in the chain (tester, end-users) needs it — just you, just once per release, then you ship the `.rbf`.

## Licensing

Our RTL and all vendored code are GPL v3 / v2+ compatible. Compiled `.rbf` is a derivative — redistribute freely alongside source (or a link to source). See [source/README.md](source/README.md) § Licensing for attribution chain.
