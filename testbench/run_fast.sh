#!/bin/bash
# Launch the NMK16 sim with an instant post-boot snapshot.
# First run auto-generates the snapshot (~30 s once).
# Subsequent runs resume in ~0.3 s — skips the long CPU boot entirely.
#
# Re-generates the snapshot automatically if the sim binary is newer
# (i.e. you rebuilt the RTL) — Verilator's savable format is pinned to
# the exact build, so a stale snapshot would be rejected anyway.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OBJ_DIR="$SCRIPT_DIR/obj_dir"
SIM="$OBJ_DIR/sim_phase4_sdl"
SNAPSHOT="$SCRIPT_DIR/boot.state"
SNAPSHOT_FRAME=200         # bump this if you want a later/later boot point

if [ ! -x "$SIM" ]; then
    echo "error: sim binary not built yet."
    echo "       cd $SCRIPT_DIR && make phase4_sdl"
    exit 1
fi

need_regen=0
if [ ! -f "$SNAPSHOT" ]; then
    need_regen=1
elif [ "$SIM" -nt "$SNAPSHOT" ]; then
    echo "[run_fast] sim binary is newer than snapshot — regenerating."
    need_regen=1
fi

if [ "$need_regen" = "1" ]; then
    echo "[run_fast] building post-boot snapshot (~30 s, one-time) ..."
    cd "$OBJ_DIR"
    "$SIM" \
        --save-at $SNAPSHOT_FRAME \
        --save-to "$SNAPSHOT" \
        --exit-after $((SNAPSHOT_FRAME + 1))
    echo "[run_fast] snapshot ready: $SNAPSHOT"
fi

echo "[run_fast] launching — ESC to quit, F12 for PPM, P to pause."
cd "$OBJ_DIR"
exec "$SIM" --load-from "$SNAPSHOT"
