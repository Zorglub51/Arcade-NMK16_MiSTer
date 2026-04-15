// NMK_Core Phase 2 simulation harness.
// Headless. Runs CPU+IRQ+memmap stub for N video frames, traces:
//   - bus cycles (CPU side)
//   - IRQ events (level transitions, IACK acknowledgements)
//   - frame markers
//
// Usage:
//   ./sim_phase2 [--frames N] [--trace path] [--bus-trace path]
//
// `--trace` (default nmk16_irq.log)  : IRQ + frame events (small, human-readable)
// `--bus-trace` (off by default)     : every bus cycle (large, like Phase 1)

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>

#include "Vnmk16_phase2_top.h"
#include "verilated.h"

static const char* fc_name(int fc) {
    switch (fc & 7) {
        case 1: return "Udata";
        case 2: return "Uprog";
        case 5: return "Sdata";
        case 6: return "Sprog";
        case 7: return "Iack";
        default: return "----";
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    int max_frames     = 5;
    const char* tpath  = "nmk16_irq.log";
    const char* bpath  = nullptr;          // off by default

    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--frames")    && i+1 < argc) max_frames = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--trace")     && i+1 < argc) tpath      = argv[++i];
        else if (!strcmp(argv[i], "--bus-trace") && i+1 < argc) bpath      = argv[++i];
    }

    FILE* tf = fopen(tpath, "w");
    if (!tf) { perror(tpath); return 1; }
    fprintf(tf, "# Phase 2 IRQ trace — IPL transitions, IACK cycles, frame ticks\n");

    FILE* bf = nullptr;
    if (bpath) {
        bf = fopen(bpath, "w");
        if (!bf) { perror(bpath); return 1; }
        fprintf(bf, "# Phase 2 bus-cycle trace\n");
    }

    auto* top = new Vnmk16_phase2_top;

    // Constant inputs: all keys released (active-low → all 1s),
    //                  DIPs at MAME defaults (all 1s = SW off).
    top->in0_keys = 0xFF;
    top->in1_keys = 0xFFFF;
    top->dsw1     = 0xFF;
    top->dsw2     = 0xFF;

    // Reset: hold pwrUp+extReset for plenty of cycles
    top->rst = 1;
    top->clk = 0;
    for (int i = 0; i < 64; i++) {
        top->clk = !top->clk;
        top->eval();
    }
    top->rst = 0;

    // Per-frame state tracked for scheduling stop
    long long cycles    = 0;
    int       frame     = 0;
    int       prev_vpos = -1;
    bool      prev_as   = true;
    int       prev_ipl  = 0;
    bool      first_iack_seen = false;

    while (frame < max_frames) {
        // Rising edge
        top->clk = 1;
        top->eval();

        int  vpos    = top->vpos_out;
        int  hpos    = top->hpos_out;
        int  ipl     = top->irq_ipl;
        bool as      = top->cpu_as_n;
        int  fc      = top->cpu_fc & 7;
        bool ackpulse= top->irq_ack_pulse;

        // Frame marker on vpos wrap
        if (prev_vpos != -1 && vpos == 0 && prev_vpos != 0) {
            frame++;
            fprintf(tf, "[frame %d  cyc=%lld]\n", frame, cycles);
        }
        prev_vpos = vpos;

        // IPL transitions
        if (ipl != prev_ipl) {
            fprintf(tf, "  cyc=%-9lld vpos=%-3d hpos=%-3d  IPL %d -> %d\n",
                    cycles, vpos, hpos, prev_ipl, ipl);
            prev_ipl = ipl;
        }

        // IACK cycle
        if (prev_as && !as && fc == 7) {
            uint32_t addr = uint32_t(top->cpu_addr) << 1;
            fprintf(tf, "  cyc=%-9lld vpos=%-3d  IACK level=%d (addr=%06X)\n",
                    cycles, vpos, (addr >> 1) & 7, addr);
        }
        if (ackpulse) {
            if (!first_iack_seen) {
                fprintf(tf, "  cyc=%-9lld first IACK clear pulse\n", cycles);
                first_iack_seen = true;
            }
        }

        // First fetch after IACK = ISR entry — log up to 8 fetches after each IACK
        // (cheap heuristic: log all Sprog reads while IPL changes happen)
        if (prev_as && !as && bf) {
            uint32_t addr = uint32_t(top->cpu_addr) << 1;
            bool     rw   = top->cpu_rw;
            uint16_t data = rw ? top->cpu_din : top->cpu_dout;
            fprintf(bf, "CYC=%-9lld vpos=%-3d FC=%s ADDR=%06X %s DATA=%04X\n",
                    cycles, vpos, fc_name(fc), addr, rw ? "R" : "W", data);
        }

        prev_as = as;

        // Falling edge
        top->clk = 0;
        top->eval();

        cycles++;
        if (cycles > 40000000LL) {       // safety cap
            fprintf(tf, "[cycle cap reached at frame %d]\n", frame);
            break;
        }
    }

    fprintf(tf, "[done — %d frames, %lld cycles]\n", frame, cycles);
    printf("Stopped at cycle %lld, frame %d.\n", cycles, frame);
    printf("IRQ trace: %s\n", tpath);
    if (bf) printf("Bus trace: %s\n", bpath);

    fclose(tf);
    if (bf) fclose(bf);
    top->final();
    delete top;
    return 0;
}
