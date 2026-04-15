// NMK_Core simulation harness — Verilator + SDL2.
// Phase 0: drives nmk16_test_pattern, opens a window, displays the active
// 256x224 frame upscaled, dumps a PPM on F12, quits on ESC.
//
// When real RTL lands, swap Vnmk16_test_pattern for Vtop and reuse the same
// pixel/HSYNC/VSYNC capture logic. Audio is left as a stub for Phase 5.

#include <SDL.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>

#include "Vnmk16_test_pattern.h"
#include "verilated.h"

static const int SCREEN_W = 256;
static const int SCREEN_H = 224;
static const int SCALE    = 3;          // window = 768 x 672

static Vnmk16_test_pattern* top      = nullptr;
static SDL_Window*          window   = nullptr;
static SDL_Renderer*        renderer = nullptr;
static SDL_Texture*         texture  = nullptr;

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
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return false;
    }
    window = SDL_CreateWindow(
        "NMK_Core sim (Phase 0 — test pattern)",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        SCREEN_W * SCALE, SCREEN_H * SCALE,
        SDL_WINDOW_SHOWN);
    if (!window) { fprintf(stderr, "SDL_CreateWindow: %s\n", SDL_GetError()); return false; }

    renderer = SDL_CreateRenderer(window, -1,
                  SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!renderer) { fprintf(stderr, "SDL_CreateRenderer: %s\n", SDL_GetError()); return false; }

    texture = SDL_CreateTexture(renderer,
                  SDL_PIXELFORMAT_ARGB8888,
                  SDL_TEXTUREACCESS_STREAMING,
                  SCREEN_W, SCREEN_H);
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

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    int max_frames = 0;          // 0 = run until window closed
    bool dump_first_frame = false;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--frames") && i + 1 < argc)
            max_frames = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--dump-frame1"))
            dump_first_frame = true;
    }

    top = new Vnmk16_test_pattern;

    if (!init_sdl()) { cleanup(); return 1; }

    // Reset
    top->reset = 1;
    top->clk   = 0;
    for (int i = 0; i < 10; i++) {
        top->clk = !top->clk;
        top->eval();
    }
    top->reset = 0;

    printf("Sim running. ESC to quit, F12 to dump PPM.\n");

    bool running    = true;
    int  pixel_x    = 0;
    int  pixel_y    = 0;
    int  frame      = 0;
    bool prev_hsync = true;
    bool prev_vsync = true;

    while (running) {
        SDL_Event ev;
        while (SDL_PollEvent(&ev)) {
            if (ev.type == SDL_QUIT) running = false;
            else if (ev.type == SDL_KEYDOWN) {
                if (ev.key.keysym.sym == SDLK_ESCAPE) running = false;
                if (ev.key.keysym.sym == SDLK_F12) {
                    char path[64];
                    snprintf(path, sizeof(path), "frame_%05d.ppm", frame);
                    dump_ppm(path);
                }
            }
        }

        // Rising edge
        top->clk = 1;
        top->eval();

        bool hsync = top->vga_hsync;
        bool vsync = top->vga_vsync;

        if (top->vga_de) {
            if (pixel_x < SCREEN_W && pixel_y < SCREEN_H) {
                framebuffer[pixel_y * SCREEN_W + pixel_x] =
                    0xFF000000u
                  | (uint32_t(top->vga_r) << 16)
                  | (uint32_t(top->vga_g) <<  8)
                  |  uint32_t(top->vga_b);
            }
            pixel_x++;
        }

        // Falling edge of HSYNC = end of scanline
        if (prev_hsync && !hsync) {
            pixel_x = 0;
            pixel_y++;
        }

        // Falling edge of VSYNC = end of frame
        if (prev_vsync && !vsync) {
            SDL_UpdateTexture(texture, nullptr, framebuffer, SCREEN_W * sizeof(uint32_t));
            SDL_RenderClear(renderer);
            SDL_RenderCopy(renderer, texture, nullptr, nullptr);
            SDL_RenderPresent(renderer);

            if (frame == 1 && dump_first_frame) dump_ppm("frame_00001.ppm");

            pixel_x = 0;
            pixel_y = 0;
            frame++;
            if (max_frames > 0 && frame >= max_frames) running = false;
        }

        prev_hsync = hsync;
        prev_vsync = vsync;

        // Falling edge
        top->clk = 0;
        top->eval();
    }

    printf("Stopped after %d frame(s).\n", frame);
    cleanup();
    return 0;
}
