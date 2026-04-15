# NMK_Core simulation harness — Verilator + SDL2 (macOS / Linux).
#
# Phase 0 target: nmk16_test_pattern. Builds a tiny verilated model + SDL display
# to confirm the toolchain works before any real RTL is written.
#
# Usage:
#   make            # build the test pattern
#   make run        # build + run; ESC quits, F12 dumps a PPM
#   make clean      # rm obj_dir
#
# When real RTL lands later, add a `nmk16` target with the real source list.

VERILATOR = verilator
RTL_DIR   = ../rtl
TB_DIR    = .
OBJ_DIR   = obj_dir

SDL_CFLAGS  = $(shell sdl2-config --cflags)
SDL_LDFLAGS = $(shell sdl2-config --libs)

# ----------------------------------------------------------------------
# Phase 0 — test pattern
# ----------------------------------------------------------------------
TP_MODULE  = nmk16_test_pattern
TP_RTL_SRC = $(TB_DIR)/$(TP_MODULE).sv
TP_SIM_SRC = $(TB_DIR)/nmk16_sim_main.cpp

TP_VFLAGS  = --cc --exe --build \
             -Wall \
             -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
             --top-module $(TP_MODULE) \
             -CFLAGS "-std=c++17 $(SDL_CFLAGS)" \
             -LDFLAGS "$(SDL_LDFLAGS)" \
             -o sim_$(TP_MODULE)

.PHONY: all run clean test_pattern phase1 run_phase1 phase2 run_phase2 phase3 run_phase3 phase4 run_phase4 phase4_sdl run_phase4_sdl hex

all: test_pattern

# ----------------------------------------------------------------------
# Phase 1 — fx68k + ROM + WRAM, headless, traces every bus cycle
# ----------------------------------------------------------------------
P1_MODULE  = nmk16_phase1_top
P1_RTL_SRC = $(TB_DIR)/$(P1_MODULE).sv $(RTL_DIR)/cpu/fx68k/fx68k.sv \
             $(RTL_DIR)/cpu/fx68k/fx68kAlu.sv $(RTL_DIR)/cpu/fx68k/uaddrPla.sv
P1_SIM_SRC = $(TB_DIR)/nmk16_phase1_main.cpp
ROM_HEX    = $(abspath ../roms/hachamfb_prog.hex)
P1_VFLAGS  = --cc --exe --build --no-assert \
             -Wall -O3 \
             +define+ROM_PATH=\"$(ROM_HEX)\" \
             -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
             -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY \
             -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-SYNCASYNCNET \
             -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-CASEX -Wno-LATCH \
             -Wno-ALWCOMBORDER -Wno-INITIALDLY -Wno-ZERODLY \
             -Wno-VARHIDDEN -Wno-SELRANGE -Wno-CMPCONST \
             -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
             --top-module $(P1_MODULE) \
             -CFLAGS "-std=c++17 -O2" \
             -o sim_$(P1_MODULE)

# microrom.mem and nanorom.mem must be alongside fx68k.sv at runtime
HEX_FILE = $(ROOT_DIR)../roms/hachamfb_prog.hex
ROOT_DIR = $(TB_DIR)/

hex:
	python3 $(TB_DIR)/build_hachamfb_hex.py

phase1: $(OBJ_DIR)/sim_$(P1_MODULE)

$(OBJ_DIR)/sim_$(P1_MODULE): $(P1_RTL_SRC) $(P1_SIM_SRC) hex
	$(VERILATOR) $(P1_VFLAGS) $(P1_RTL_SRC) $(P1_SIM_SRC)
	cp $(RTL_DIR)/cpu/fx68k/microrom.mem $(OBJ_DIR)/
	cp $(RTL_DIR)/cpu/fx68k/nanorom.mem  $(OBJ_DIR)/

run_phase1: phase1
	cd $(OBJ_DIR) && ./sim_$(P1_MODULE) --trace ../nmk16_trace.log

# ----------------------------------------------------------------------
# Phase 2 — fx68k + irq + memmap stub. Verifies CPU enters ISRs.
# ----------------------------------------------------------------------
P2_MODULE  = nmk16_phase2_top
P2_RTL_SRC = $(TB_DIR)/$(P2_MODULE).sv $(RTL_DIR)/irq.sv \
             $(RTL_DIR)/cpu/fx68k/fx68k.sv \
             $(RTL_DIR)/cpu/fx68k/fx68kAlu.sv $(RTL_DIR)/cpu/fx68k/uaddrPla.sv
P2_SIM_SRC = $(TB_DIR)/nmk16_phase2_main.cpp
P2_VFLAGS  = --cc --exe --build --no-assert \
             -Wall -O3 \
             +define+ROM_PATH=\"$(ROM_HEX)\" \
             -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
             -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY \
             -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-SYNCASYNCNET \
             -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-CASEX -Wno-LATCH \
             -Wno-ALWCOMBORDER -Wno-INITIALDLY -Wno-ZERODLY \
             -Wno-VARHIDDEN -Wno-SELRANGE -Wno-CMPCONST \
             -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
             --top-module $(P2_MODULE) \
             -CFLAGS "-std=c++17 -O2" \
             -o sim_$(P2_MODULE)

phase2: $(OBJ_DIR)/sim_$(P2_MODULE)

$(OBJ_DIR)/sim_$(P2_MODULE): $(P2_RTL_SRC) $(P2_SIM_SRC) hex
	$(VERILATOR) $(P2_VFLAGS) $(P2_RTL_SRC) $(P2_SIM_SRC)
	cp $(RTL_DIR)/cpu/fx68k/microrom.mem $(OBJ_DIR)/
	cp $(RTL_DIR)/cpu/fx68k/nanorom.mem  $(OBJ_DIR)/

run_phase2: phase2
	cd $(OBJ_DIR) && ./sim_$(P2_MODULE) --trace ../nmk16_irq.log

# ----------------------------------------------------------------------
# Phase 3 — adds tilemap rendering. Headless PPM dumps.
# ----------------------------------------------------------------------
P3_MODULE  = nmk16_phase3_top
P3_RTL_SRC = $(TB_DIR)/$(P3_MODULE).sv $(RTL_DIR)/irq.sv $(RTL_DIR)/tilemap.sv \
             $(RTL_DIR)/cpu/fx68k/fx68k.sv \
             $(RTL_DIR)/cpu/fx68k/fx68kAlu.sv $(RTL_DIR)/cpu/fx68k/uaddrPla.sv
P3_SIM_SRC = $(TB_DIR)/nmk16_phase3_main.cpp
BG_GFX_HEX = $(abspath ../roms/hachamf_bg.hex)
TX_GFX_HEX = $(abspath ../roms/hachamf_tx.hex)
P3_VFLAGS  = --cc --exe --build --no-assert \
             -Wall -O3 \
             +define+ROM_PATH=\"$(ROM_HEX)\" \
             +define+BG_GFX_PATH=\"$(BG_GFX_HEX)\" \
             +define+TX_GFX_PATH=\"$(TX_GFX_HEX)\" \
             -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
             -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY \
             -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-SYNCASYNCNET \
             -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-CASEX -Wno-LATCH \
             -Wno-ALWCOMBORDER -Wno-INITIALDLY -Wno-ZERODLY \
             -Wno-VARHIDDEN -Wno-SELRANGE -Wno-CMPCONST \
             -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
             --top-module $(P3_MODULE) \
             -CFLAGS "-std=c++17 -O2" \
             -o sim_$(P3_MODULE)

phase3: $(OBJ_DIR)/sim_$(P3_MODULE)

$(OBJ_DIR)/sim_$(P3_MODULE): $(P3_RTL_SRC) $(P3_SIM_SRC) hex
	$(VERILATOR) $(P3_VFLAGS) $(P3_RTL_SRC) $(P3_SIM_SRC)
	cp $(RTL_DIR)/cpu/fx68k/microrom.mem $(OBJ_DIR)/
	cp $(RTL_DIR)/cpu/fx68k/nanorom.mem  $(OBJ_DIR)/

run_phase3: phase3
	cd $(OBJ_DIR) && ./sim_$(P3_MODULE) --trace ../nmk16_phase3.log

# ----------------------------------------------------------------------
# Phase 4 — adds sprite engine on top of Phase 3.
# ----------------------------------------------------------------------
P4_MODULE   = nmk16_phase4_top
P4_RTL_SRC  = $(TB_DIR)/$(P4_MODULE).sv $(RTL_DIR)/irq.sv $(RTL_DIR)/tilemap.sv \
              $(RTL_DIR)/cpu/fx68k/fx68k.sv \
              $(RTL_DIR)/cpu/fx68k/fx68kAlu.sv $(RTL_DIR)/cpu/fx68k/uaddrPla.sv
P4_SIM_SRC  = $(TB_DIR)/nmk16_phase4_main.cpp
SPR_GFX_HEX = $(abspath ../roms/hachamf_spr.hex)
ROM_BIN_F  = $(abspath ../roms/hachamfb_prog.bin)
BG_GFX_BIN = $(abspath ../roms/hachamf_bg.bin)
TX_GFX_BIN = $(abspath ../roms/hachamf_tx.bin)
SPR_GFX_BIN= $(abspath ../roms/hachamf_spr.bin)
P4_VFLAGS   = --cc --exe --build --no-assert \
              -Wall -O3 \
              +define+ROM_BIN=\"$(ROM_BIN_F)\" \
              +define+BG_GFX_BIN=\"$(BG_GFX_BIN)\" \
              +define+TX_GFX_BIN=\"$(TX_GFX_BIN)\" \
              +define+SPR_GFX_BIN=\"$(SPR_GFX_BIN)\" \
              -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
              -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY \
              -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-SYNCASYNCNET \
              -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-CASEX -Wno-LATCH \
              -Wno-ALWCOMBORDER -Wno-INITIALDLY -Wno-ZERODLY \
              -Wno-VARHIDDEN -Wno-SELRANGE -Wno-CMPCONST \
              -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
              --top-module $(P4_MODULE) \
              -CFLAGS "-std=c++17 -O2" \
              -o sim_$(P4_MODULE)

phase4: $(OBJ_DIR)/sim_$(P4_MODULE)

$(OBJ_DIR)/sim_$(P4_MODULE): $(P4_RTL_SRC) $(P4_SIM_SRC) hex
	$(VERILATOR) $(P4_VFLAGS) $(P4_RTL_SRC) $(P4_SIM_SRC)
	cp $(RTL_DIR)/cpu/fx68k/microrom.mem $(OBJ_DIR)/
	cp $(RTL_DIR)/cpu/fx68k/nanorom.mem  $(OBJ_DIR)/

run_phase4: phase4
	cd $(OBJ_DIR) && ./sim_$(P4_MODULE) --trace ../nmk16_phase4.log

# ----------------------------------------------------------------------
# Phase 4 SDL — same RTL as phase4, driven by SDL window + keyboard.
# ----------------------------------------------------------------------
P4SDL_SIM_SRC = $(TB_DIR)/nmk16_phase4_sdl.cpp
P4SDL_VFLAGS  = --cc --exe --build --no-assert --savable \
                -Wall -O3 --x-assign fast --x-initial fast \
                +define+PIX_DIV_VAL=4 \
                +define+ROM_BIN=\"$(ROM_BIN_F)\" \
                +define+BG_GFX_BIN=\"$(BG_GFX_BIN)\" \
                +define+TX_GFX_BIN=\"$(TX_GFX_BIN)\" \
                +define+SPR_GFX_BIN=\"$(SPR_GFX_BIN)\" \
                -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
                -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY \
                -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-SYNCASYNCNET \
                -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-CASEX -Wno-LATCH \
                -Wno-ALWCOMBORDER -Wno-INITIALDLY -Wno-ZERODLY \
                -Wno-VARHIDDEN -Wno-SELRANGE -Wno-CMPCONST \
                -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
                --top-module $(P4_MODULE) \
                -CFLAGS "-std=c++17 -O3 -march=native -flto -include $(abspath fx68k_save_shim.h) $(SDL_CFLAGS)" \
                -LDFLAGS "-flto $(SDL_LDFLAGS)" \
                -o sim_phase4_sdl

phase4_sdl: $(OBJ_DIR)/sim_phase4_sdl

$(OBJ_DIR)/sim_phase4_sdl: $(P4_RTL_SRC) $(P4SDL_SIM_SRC) hex
	$(VERILATOR) $(P4SDL_VFLAGS) $(P4_RTL_SRC) $(P4SDL_SIM_SRC)
	cp $(RTL_DIR)/cpu/fx68k/microrom.mem $(OBJ_DIR)/
	cp $(RTL_DIR)/cpu/fx68k/nanorom.mem  $(OBJ_DIR)/

run_phase4_sdl: phase4_sdl
	cd $(OBJ_DIR) && ./sim_phase4_sdl

test_pattern: $(OBJ_DIR)/sim_$(TP_MODULE)

$(OBJ_DIR)/sim_$(TP_MODULE): $(TP_RTL_SRC) $(TP_SIM_SRC)
	$(VERILATOR) $(TP_VFLAGS) $(TP_RTL_SRC) $(TP_SIM_SRC)

run: test_pattern
	./$(OBJ_DIR)/sim_$(TP_MODULE)

clean:
	rm -rf $(OBJ_DIR) frame_*.ppm
