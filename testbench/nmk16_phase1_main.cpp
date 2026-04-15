// NMK_Core Phase 1 simulation harness.
// Runs the FX68K against ROM+WRAM stub and traces every bus cycle.
//
// Usage:
//   ./sim_phase1 [--cycles N] [--trace path]
//
// Trace format (one line per bus cycle, written when ASn falls):
//   CYC=<cycle>  FC=<fc>  ADDR=<24-bit hex>  RW=<R|W>  DATA=<word>  [UDS|LDS]
// FC values: 010 = user data, 110 = supervisor data, 011 = user prog,
//            111 = supervisor prog, 111 + AS+UDS+LDS+RW = IACK.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>

#include "Vnmk16_phase1_top.h"
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

    long long max_cycles = 200000;        // ~3 ms of CPU time at 10 MHz / 2-clk-per-phi
    const char* trace_path = "nmk16_trace.log";

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--cycles") && i + 1 < argc)
            max_cycles = atoll(argv[++i]);
        else if (!strcmp(argv[i], "--trace") && i + 1 < argc)
            trace_path = argv[++i];
    }

    FILE* tf = fopen(trace_path, "w");
    if (!tf) { perror(trace_path); return 1; }
    fprintf(tf, "# Phase 1 trace — every bus cycle (one line per ASn falling edge)\n");

    auto* top = new Vnmk16_phase1_top;

    // Reset
    top->rst = 1;
    top->clk = 0;
    for (int i = 0; i < 16; i++) {
        top->clk = !top->clk;
        top->eval();
    }
    top->rst = 0;

    bool prev_as = true;
    long long bus_cycles = 0;
    long long cycles = 0;

    while (cycles < max_cycles) {
        // Rising edge
        top->clk = 1;
        top->eval();

        bool as = top->cpu_as_n;
        if (prev_as && !as) {
            // ASn just fell — a new bus cycle begins
            uint32_t addr   = uint32_t(top->cpu_addr) << 1;     // 24-bit byte address
            int      fc     = top->cpu_fc & 7;
            bool     rw     = top->cpu_rw;
            uint16_t data   = rw ? top->cpu_din : top->cpu_dout;
            bool     uds    = !top->cpu_uds_n;
            bool     lds    = !top->cpu_lds_n;

            fprintf(tf, "CYC=%-9lld  FC=%s  ADDR=%06X  %s  DATA=%04X  %s%s\n",
                    cycles, fc_name(fc), addr, rw ? "R" : "W", data,
                    uds ? "U" : "-", lds ? "L" : "-");
            bus_cycles++;
        }
        prev_as = as;

        // Falling edge
        top->clk = 0;
        top->eval();

        cycles++;
    }

    printf("Stopped at cycle %lld; %lld bus cycles seen.\n", cycles, bus_cycles);
    printf("Trace written to %s\n", trace_path);

    fclose(tf);
    top->final();
    delete top;
    return 0;
}
