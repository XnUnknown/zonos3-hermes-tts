#!/usr/bin/env bash
# Zonos3 TTS server for WSL  (the Zonos equivalent of kokoro_server.py)
#
# Loads the model once, keeps it resident on a local HTTP port, and answers the
# OpenAI-compatible endpoint POST /v1/audio/speech, so every voice note after the
# first costs a request instead of a model load.
#
#   bash zonos3_server.sh                 # start (default port 1919)
#   bash zonos3_server.sh stop            # stop
#   bash zonos3_server.sh status          # health check
#   ZONOS_PORT=2000 bash zonos3_server.sh
#   ZONOS_ROOT=~/somewhere/ZONOS3-Mini bash zonos3_server.sh

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${ZONOS_PORT:-1919}"
ROOT="${ZONOS_ROOT:-$HERE}"
GGML="$ROOT/servers/ggml"
BIN="$GGML/build-cuda/zonos3-server"
LOG="${ZONOS_LOG:-$HOME/zonos3-server.log}"
HF_BASE="${ZONOS_HF_BASE:-https://huggingface.co/Zyphra/ZONOS3-Mini/resolve/main/gguf}"

# remote name : local name
WEIGHTS=(
    "backbone-ptq.gguf:zonos3-ptq.gguf"
    "zac-keep2.gguf:zac-keep2.gguf"
    "spk-encoder.gguf:spk-encoder.gguf"
)

# First run downloads the weights (about 1.1 GB, public, no token). Present weights are
# left alone, partial downloads resume.
fetch_weights() {
    mkdir -p "$GGML/gguf" || return 1
    local entry remote local_name path
    for entry in "${WEIGHTS[@]}"; do
        remote="${entry%%:*}"
        local_name="${entry##*:}"
        path="$GGML/gguf/$local_name"
        if [ -s "$path" ] && [ "$(stat -c%s "$path")" -gt 10000000 ]; then
            echo "  have $local_name ($(du -h "$path" | cut -f1))"
            continue
        fi
        echo "  downloading $local_name"
        if ! curl -L --fail --progress-bar -C - -o "$path" "$HF_BASE/$remote"; then
            echo "download failed for $remote" >&2
            echo "fetch it by hand from https://huggingface.co/Zyphra/ZONOS3-Mini/tree/main/gguf" >&2
            return 1
        fi
    done
    echo "  weights ready"
    return 0
}

health() {
    curl -sf --max-time 2 "http://127.0.0.1:$PORT/v2/health" >/dev/null 2>&1
}

case "${1:-start}" in
stop)
    pkill -f "zonos3-server gguf" && echo "stopped" || echo "not running"
    exit 0
    ;;
status)
    if health; then echo "running on $PORT"; curl -s "http://127.0.0.1:$PORT/v2/health"; echo
    else echo "not running on $PORT"; exit 1
    fi
    exit 0
    ;;
fetch)
    fetch_weights
    exit $?
    ;;
start) ;;
*) echo "usage: bash zonos3_server.sh [start|stop|status|fetch]" >&2; exit 64 ;;
esac

if health; then
    echo "zonos3-server already running on port $PORT"
    exit 0
fi

if [ ! -x "$BIN" ]; then
    echo "missing binary: $BIN" >&2
    echo "unzip the bundle somewhere and run this script from inside it (or set ZONOS_ROOT)" >&2
    exit 1
fi

echo "checking model weights"
fetch_weights || exit 1

# The binary was compiled with a RUNPATH pointing at the build machine's home
# directory and it links the CUDA runtime. Point the loader at the libraries that
# travel with the tree so it works from any path, on any machine.
export LD_LIBRARY_PATH="$GGML/build-cuda/ggml/src:$GGML/build-cuda/ggml/src/ggml-cuda:$ROOT/cuda-libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

cd "$GGML" || exit 1

VOICES=()
if [ -d "$ROOT/voices" ]; then
    VOICES=(--tts-default-voices-dir "$ROOT/voices")
elif [ -d gguf/voices ]; then
    VOICES=(--tts-default-voices-dir gguf/voices)
fi

nohup "$BIN" gguf/zonos3-ptq.gguf --gpu --host 127.0.0.1 --port "$PORT" "${VOICES[@]}" \
    >>"$LOG" 2>&1 &

echo "starting zonos3-server on port $PORT (log: $LOG)"

i=0
while [ "$i" -lt 90 ]; do
    if health; then
        echo "ready: http://127.0.0.1:$PORT"
        exit 0
    fi
    sleep 1
    i=$((i + 1))
done

echo "did not become healthy in 90s. last lines of $LOG:" >&2
tail -n 15 "$LOG" >&2
exit 2
