// NMK_Core Phase 4 simulation harness (headless).
// Runs the CPU + tilemap, captures the active-area framebuffer per frame,
// dumps PPMs at user-specified frames.
//
// Usage:
//   ./sim_phase4 [--frames N] [--dump-frames a,b,c]
//                [--dump-each]   (dump every frame, watch out — slow)
//                [--trace path]  (IRQ trace)
//
// Default: --frames 80 --dump-frames 60,70,80

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>
#include <set>
#include <string>
#include <sstream>

#include "Vnmk16_phase4_top.h"
#include "verilated.h"

static const int SCREEN_W = 256;
static const int SCREEN_H = 224;

static uint32_t framebuffer[SCREEN_W * SCREEN_H];

static void dump_ppm(const char* path) {
    FILE* f = fopen(path, "wb");
    if (!f) { perror(path); return; }
    fprintf(f, "P6\n%d %d\n255\n", SCREEN_W, SCREEN_H);
    for (int i = 0; i < SCREEN_W * SCREEN_H; i++) {
        uint32_t c = framebuffer[i];
        uint8_t rgb[3] = {
            uint8_t((c >> 16) & 0xFF),
            uint8_t((c >>  8) & 0xFF),
            uint8_t( c        & 0xFF)
        };
        fwrite(rgb, 1, 3, f);
    }
    fclose(f);
    printf("dumped %s\n", path);
}

static std::set<int> parse_csv_int(const char* s) {
    std::set<int> r;
    std::stringstream ss(s);
    std::string tok;
    while (std::getline(ss, tok, ',')) if (!tok.empty()) r.insert(atoi(tok.c_str()));
    return r;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    int max_frames    = 80;
    bool dump_each    = false;
    std::set<int> dump_frames = {60, 70, 80};
    const char* tpath = "nmk16_phase4.log";
    const char* iopath = nullptr;      // IO-region trace, opt-in
    int io_trace_frame_lo = 0;
    int io_trace_frame_hi = 999999;

    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--frames")     && i+1 < argc) max_frames  = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--trace")      && i+1 < argc) tpath       = argv[++i];
        else if (!strcmp(argv[i], "--dump-each"))                dump_each   = true;
        else if (!strcmp(argv[i], "--dump-frames")&& i+1 < argc) dump_frames = parse_csv_int(argv[++i]);
        else if (!strcmp(argv[i], "--io-trace")   && i+1 < argc) iopath      = argv[++i];
        else if (!strcmp(argv[i], "--io-frames")  && i+1 < argc) {
            char* s = argv[++i]; char* dash = strchr(s, '-');
            if (dash) { *dash = 0; io_trace_frame_lo = atoi(s); io_trace_frame_hi = atoi(dash+1); }
        }
    }

    FILE* tf = fopen(tpath, "w");
    if (!tf) { perror(tpath); return 1; }
    fprintf(tf, "# Phase 4 trace — frames + IRQ ticks\n");

    FILE* iof = nullptr;
    if (iopath) {
        iof = fopen(iopath, "w");
        if (!iof) { perror(iopath); return 1; }
        fprintf(iof, "# IO-region trace (CPU accesses in $080000-$0800FF + scroll/palette)\n");
    }

    auto* top = new Vnmk16_phase4_top;
    top->in0_keys = 0xFF;
    top->in1_keys = 0xFFFF;
    top->dsw1     = 0xFF;
    top->dsw2     = 0xFF;

    // Reset
    top->rst = 1;
    top->clk = 0;
    for (int i = 0; i < 64; i++) {
        top->clk = !top->clk;
        top->eval();
    }
    top->rst = 0;

    long long cycles    = 0;
    int       frame     = 0;
    int       prev_vpos = -1;
    int       prev_ipl  = 0;
    int       prev_hpos = -1;
    int       pixel_x   = -1;
    int       pixel_y   = -1;
    int       last_vpos = -1;
    bool      prev_as   = true;

    while (frame < max_frames) {
        // Rising edge
        top->clk = 1;
        top->eval();

        int  vpos = top->vpos_out;
        int  hpos = top->hpos_out;
        int  ipl  = top->irq_ipl;
        bool de   = top->vga_de;

        // Active-area cursor based on vga_de pulses
        if (de) {
            if (hpos != prev_hpos) {
                // New pixel — but we use derived pixel_x for safety
                if (pixel_x < 0) pixel_x = 0;
                if (pixel_x < SCREEN_W && pixel_y >= 0 && pixel_y < SCREEN_H) {
                    framebuffer[pixel_y * SCREEN_W + pixel_x] =
                        0xFF000000u
                      | (uint32_t(top->vga_r) << 16)
                      | (uint32_t(top->vga_g) <<  8)
                      |  uint32_t(top->vga_b);
                }
                pixel_x++;
            }
        } else {
            // End of active line — reset x; advance y on a real new line
            if (pixel_x >= 0) {
                pixel_x = -1;
                if (vpos != last_vpos) {
                    pixel_y++;
                    last_vpos = vpos;
                }
            }
        }

        // Frame marker
        if (prev_vpos != -1 && vpos == 0 && prev_vpos != 0) {
            frame++;
            fprintf(tf, "[frame %d  cyc=%lld]\n", frame, cycles);
            if (dump_each || dump_frames.count(frame)) {
                char path[64];
                snprintf(path, sizeof(path), "frame_%05d.ppm", frame);
                dump_ppm(path);
            }
            pixel_y = 0;       // reset framebuffer y cursor at frame top
            last_vpos = -1;
        }
        prev_vpos = vpos;
        prev_hpos = hpos;

        // I/O-region bus-cycle trace — only log on ASn falling edge to get one
        // line per bus cycle, filtered to I/O addresses $080000-$08FFFF.
        if (iof && frame >= io_trace_frame_lo && frame <= io_trace_frame_hi) {
            bool as = top->cpu_as_n;
            if (prev_as && !as) {
                uint32_t addr = uint32_t(top->cpu_addr) << 1;
                if ((addr & 0xFF0000) == 0x080000) {
                    bool rw = top->cpu_rw;
                    uint16_t data = rw ? top->cpu_din : top->cpu_dout;
                    bool uds = !top->cpu_uds_n_o;
                    bool lds = !top->cpu_lds_n_o;
                    fprintf(iof, "[f%d cyc=%lld vpos=%-3d] %s %06X %04X %s%s\n",
                            frame, cycles, vpos, rw ? "R" : "W", addr, data,
                            uds ? "U" : "-", lds ? "L" : "-");
                }
            }
            prev_as = as;
        }

        if (ipl != prev_ipl) {
            fprintf(tf, "  cyc=%-9lld vpos=%-3d  IPL %d -> %d\n",
                    cycles, vpos, prev_ipl, ipl);
            prev_ipl = ipl;
        }

        // Falling edge
        top->clk = 0;
        top->eval();
        cycles++;

        if (cycles > 1000000000LL) {
            fprintf(tf, "[cycle cap reached at frame %d]\n", frame);
            break;
        }
    }

    fprintf(tf, "[done — %d frames, %lld cycles]\n", frame, cycles);
    printf("Stopped at cycle %lld, frame %d.\n", cycles, frame);
    fclose(tf);
    if (iof) fclose(iof);
    top->final();
    delete top;
    return 0;
}
