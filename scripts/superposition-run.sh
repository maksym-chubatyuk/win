#!/usr/bin/env bash
# Runs Unigine Superposition's 1080p Medium benchmark on the iPhone, starting the engine
# directly (its Qt launcher crashes), and keeps screenshots under build/screens-<label>.
#
#   scripts/superposition-run.sh base
#   CONSOLE='render_shadows 0' scripts/superposition-run.sh noshadows
#
# EXTRA: engine commands added to the start-up chain, "cmd1 && cmd2". The benchmark resets
#   only its preset settings (shadows, quality, resolution) after this, so others stick.
# CONSOLE: engine console commands, separated by ";;", typed in after the benchmark starts.
# SNAPS: "seconds,count" screenshots (default 10,6).
# WIDTH, HEIGHT: the engine's render size (default 1280x720). With
#   DXMT_METALFX_SPATIAL_SWAPCHAIN=1, MetalFX upscales it by d3d11.metalSpatialUpscaleFactor
#   (default 2, set through DXMT_CONFIG).
set -euo pipefail
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="${1:-run}"

export WIN_EXE='C:\Programs\Superposition\bin\superposition.exe'
EXTRA="${EXTRA:+ && $EXTRA}"
export WIN_ARGS='-project_name "Superposition" -video_mode -1 -console_command "world_load superposition/superposition && render_manager_create_textures 1'"$EXTRA"'" -extern_plugin "GPUMonitor" -mode 0 -video_app direct3d11 -shaders_quality 0 -textures_quality 0 -video_width '"${WIDTH:-1280}"' -video_height '"${HEIGHT:-720}"' -video_fullscreen 0 -sound 0 -dof 0 -motion_blur 0'
export WIN_POOL_MB="${WIN_POOL_MB:-512}"
export WIN_AUTOTEST=1 WIN_NO_TYPING=1
export WIN_SNAPSHOT_EVERY="${SNAPS:-10,6}"
export WIN_ENGINE_CONSOLE="${CONSOLE:-}"
export WAIT_SECONDS="${WAIT_SECONDS:-400}"

"$PROJECT/scripts/jit-run.sh"
OUT="$PROJECT/build/screens-$LABEL"
rm -rf "$OUT"
cp -R "$PROJECT/build/screens" "$OUT"
cp "$PROJECT/build-logs/device-output.txt" "$OUT/output.txt" 2>/dev/null || true
echo "screenshots: $OUT"

# The engine's frame-rate summary (the base64 packet two lines after "Benchmark results";
# the number on the line between is the same in every run, so it is not the score).
python3 -I - "$OUT/output.txt" <<'PY'
import base64, struct, sys
lines = open(sys.argv[1], errors="replace").read().splitlines()
for i, line in enumerate(lines):
    if line.startswith("Benchmark results"):
        # The engine's packet starts with min, max and average frame rate as float32.
        try:
            raw = base64.b64decode(lines[i + 2].strip() + "==")
            low, high, mean = struct.unpack("<3f", raw[:12])
            print("fps: average %.1f, min %.1f, max %.1f" % (mean, low, high))
        except Exception:
            print("no frame-rate packet")
        break
else:
    print("no score yet (the benchmark had not finished)")
PY
