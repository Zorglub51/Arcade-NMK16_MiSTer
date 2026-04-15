// NMK_Core Phase 4 interactive SDL harness.
//
// Runs the fx68k + tilemap + sprite engine with a live SDL window and
// keyboard input. At PIX_DIV=16 the sim is ~0.47 s of wall time per rendered
// frame (about 2 fps in the window) — slow but visibly animated.
//
// Key map (MAME-style):
//   1 .................. START1
//   2 .................. START2
//   5 .................. COIN1
//   6 .................. COIN2
//   9 .................. SERVICE1
//   Arrow keys ......... P1 stick
//   Z ................. P1 Button 1
//   X ................. P1 Button 2
//   R / D / F / G ...... P2 stick (up/left/down/right)
//   Q / W .............. P2 Button 1 / Button 2
//   F12 ................ snapshot PPM
//   P .................. pause / resume sim
//   ESC ................ quit
//
// State snapshot (skip the 22 s boot on subsequent runs):
//   ./sim_phase4_sdl --save-at 40 --save-to boot.state      # one-time
//   ./sim_phase4_sdl --load-from boot.state                  # every run after

#include <SDL.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>

#include "Vnmk16_phase4_top.h"
#include "verilated.h"
#include "verilated_save.h"

static const int SCREEN_W = 256;
static const int SCREEN_H = 224;
static const int SCALE    = 3;

static Vnmk16_phase4_top* top      = nullptr;
static SDL_Window*        window   = nullptr;
static SDL_Renderer*      renderer = nullptr;
static SDL_Texture*       texture  = nullptr;
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

static bool init_sdl() {
    if (SDL_Init(SDL_INIT_VIDEO) < 0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError()); return false;
    }
    window = SDL_CreateWindow(
        "NMK_Core — Hacha Mecha Fighter (hachamfb) — Phase 4",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        SCREEN_W * SCALE, SCREEN_H * SCALE, SDL_WINDOW_SHOWN);
    if (!window) { fprintf(stderr, "SDL_CreateWindow: %s\n", SDL_GetError()); return false; }
    renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!renderer) { fprintf(stderr, "SDL_CreateRenderer: %s\n", SDL_GetError()); return false; }
    texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ARGB8888,
                                SDL_TEXTUREACCESS_STREAMING, SCREEN_W, SCREEN_H);
    if (!texture) { fprintf(stderr, "SDL_CreateTexture: %s\n", SDL_GetError()); return false; }
    return true;
}

static void cleanup() {
    if (texture)  SDL_DestroyTexture(texture);
    if (renderer) SDL_DestroyRenderer(renderer);
    if (window)   SDL_DestroyWindow(window);
    SDL_Quit();
    if (top) { top->final(); delete top; }
}

// Map current SDL key state to NMK16 IN0 and IN1 (both active-low).
// IN0 bits: 0=COIN1 1=COIN2 2=SERVICE1 3=START1 4=START2
// IN1 bits: 0..5 = P1 R/L/D/U/B1/B2 , 8..13 = P2 R/L/D/U/B1/B2
static void update_inputs() {
    const Uint8* k = SDL_GetKeyboardState(nullptr);

    uint8_t in0 = 0xFF
        & ~(k[SDL_SCANCODE_5] ? 0x01 : 0)
        & ~(k[SDL_SCANCODE_6] ? 0x02 : 0)
        & ~(k[SDL_SCANCODE_9] ? 0x04 : 0)
        & ~(k[SDL_SCANCODE_1] ? 0x08 : 0)
        & ~(k[SDL_SCANCODE_2] ? 0x10 : 0);

    uint16_t in1 = 0xFFFF;
    // P1
    in1 = in1
        & ~(k[SDL_SCANCODE_RIGHT] ? 0x0001 : 0)
        & ~(k[SDL_SCANCODE_LEFT]  ? 0x0002 : 0)
        & ~(k[SDL_SCANCODE_DOWN]  ? 0x0004 : 0)
        & ~(k[SDL_SCANCODE_UP]    ? 0x0008 : 0)
        & ~(k[SDL_SCANCODE_Z]     ? 0x0010 : 0)
        & ~(k[SDL_SCANCODE_X]     ? 0x0020 : 0)
    // P2
        & ~(k[SDL_SCANCODE_G]     ? 0x0100 : 0)
        & ~(k[SDL_SCANCODE_D]     ? 0x0200 : 0)
        & ~(k[SDL_SCANCODE_F]     ? 0x0400 : 0)
        & ~(k[SDL_SCANCODE_R]     ? 0x0800 : 0)
        & ~(k[SDL_SCANCODE_Q]     ? 0x1000 : 0)
        & ~(k[SDL_SCANCODE_W]     ? 0x2000 : 0);

    top->in0_keys = in0;
    top->in1_keys = in1;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    // CLI: --save-at N --save-to path --load-from path
    // --load-from skips the boot and resumes instantly at the saved frame.
    // --save-at+save-to will run until frame N, save state, then continue.
    int         save_at    = -1;
    const char* save_to    = nullptr;
    const char* load_from  = nullptr;
    int         auto_dump  = -1;   // dump PPM at this (post-start) frame index
    int         exit_after = -1;   // quit after this many frames
    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--save-at")     && i+1 < argc) save_at    = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--save-to")     && i+1 < argc) save_to    = argv[++i];
        else if (!strcmp(argv[i], "--load-from")   && i+1 < argc) load_from  = argv[++i];
        else if (!strcmp(argv[i], "--auto-dump")   && i+1 < argc) auto_dump  = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--exit-after")  && i+1 < argc) exit_after = atoi(argv[++i]);
    }

    top = new Vnmk16_phase4_top;
    top->in0_keys = 0xFF;
    top->in1_keys = 0xFFFF;
    top->dsw1     = 0xFF;
    top->dsw2     = 0xFF;

    if (!init_sdl()) { cleanup(); return 1; }

    // Pre-fill framebuffer with dark gray so the window shows *something*
    // before the first real frame is captured (sim is slow relative to SDL).
    for (int i = 0; i < SCREEN_W * SCREEN_H; i++) framebuffer[i] = 0xFF202030;
    SDL_UpdateTexture(texture, nullptr, framebuffer, SCREEN_W * sizeof(uint32_t));
    SDL_RenderClear(renderer);
    SDL_RenderCopy(renderer, texture, nullptr, nullptr);
    SDL_RenderPresent(renderer);

    if (load_from) {
        // Restore state from snapshot — skip reset, skip boot entirely.
        printf("Loading snapshot from %s ...\n", load_from);
        fflush(stdout);
        VerilatedRestore vr;
        vr.open(load_from);
        vr >> *top;
        vr.close();
        if (vr.isOpen()) {
            fprintf(stderr, "Snapshot load: unexpected stream state.\n");
        }
        printf("Snapshot loaded. Sim resumes from saved state.\n");
    } else {
        // Standard cold-start: hold reset then release
        top->rst = 1;
        top->clk = 0;
        for (int i = 0; i < 64; i++) {
            top->clk = !top->clk;
            top->eval();
        }
        top->rst = 0;
    }

    printf("Running. 5=COIN, 1=START, Arrows+Z+X=P1. ESC=quit, F12=PPM, P=pause.\n");
    if (save_at >= 0 && save_to)
        printf("Will snapshot state at frame %d to %s.\n", save_at, save_to);
    fflush(stdout);

    bool running    = true;
    bool paused     = false;
    int  pixel_x    = -1;
    int  pixel_y    = -1;
    int  frame      = 0;
    int  prev_hpos  = -1;
    int  last_vpos  = -1;
    int  prev_vpos  = -1;

    while (running) {
        // ----- Poll SDL -----
        SDL_Event ev;
        while (SDL_PollEvent(&ev)) {
            if (ev.type == SDL_QUIT) running = false;
            else if (ev.type == SDL_KEYDOWN) {
                if (ev.key.keysym.sym == SDLK_ESCAPE) running = false;
                if (ev.key.keysym.sym == SDLK_p)      paused = !paused;
                if (ev.key.keysym.sym == SDLK_F12) {
                    char path[64];
                    snprintf(path, sizeof(path), "frame_live_%05d.ppm", frame);
                    dump_ppm(path);
                }
            }
        }
        update_inputs();

        if (paused) {
            SDL_Delay(16);
            continue;
        }

        // ----- Rising edge -----
        top->clk = 1;
        top->eval();

        int vpos = top->vpos_out;
        int hpos = top->hpos_out;
        bool de  = top->vga_de;

        // Active-area pixel capture (same logic as headless main)
        if (de) {
            if (hpos != prev_hpos) {
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
            if (pixel_x >= 0) {
                pixel_x = -1;
                if (vpos != last_vpos) { pixel_y++; last_vpos = vpos; }
            }
        }

        // Frame boundary on vpos wrap
        if (prev_vpos != -1 && vpos == 0 && prev_vpos != 0) {
            frame++;
            SDL_UpdateTexture(texture, nullptr, framebuffer, SCREEN_W * sizeof(uint32_t));
            SDL_RenderClear(renderer);
            SDL_RenderCopy(renderer, texture, nullptr, nullptr);
            SDL_RenderPresent(renderer);
            pixel_y = 0;
            last_vpos = -1;

            if (save_at >= 0 && save_to && frame == save_at) {
                printf("Saving snapshot at frame %d → %s ...\n", frame, save_to);
                fflush(stdout);
                VerilatedSave vs;
                vs.open(save_to);
                vs << *top;
                vs.close();
                printf("Snapshot saved.\n");
                fflush(stdout);
            }
            if (auto_dump >= 0 && frame == auto_dump) {
                char path[64];
                snprintf(path, sizeof(path), "auto_f%05d.ppm", frame);
                dump_ppm(path);
            }
            if (exit_after >= 0 && frame >= exit_after) {
                running = false;
            }
        }
        prev_vpos = vpos;
        prev_hpos = hpos;

        // ----- Falling edge -----
        top->clk = 0;
        top->eval();
    }

    printf("Exiting after %d frames.\n", frame);
    cleanup();
    return 0;
}
