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

PORT="${ZONOS_PORT:-1919}"
ROOT="${ZONOS_ROOT:-$HOME/ZONOS3-Mini}"
GGML="$ROOT/servers/ggml"
BIN="$GGML/build-cuda/zonos3-server"
LOG="${ZONOS_LOG:-$HOME/zonos3-server.log}"

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
start) ;;
*) echo "usage: bash zonos3_server.sh [start|stop|status]" >&2; exit 64 ;;
esac

if health; then
    echo "zonos3-server already running on port $PORT"
    exit 0
fi

if [ ! -x "$BIN" ]; then
    echo "missing binary: $BIN" >&2
    echo "put the ZONOS3-Mini tree at $ROOT (or set ZONOS_ROOT)" >&2
    exit 1
fi

# The binary was compiled with a RUNPATH pointing at the build machine's home
# directory and it links the CUDA runtime. Point the loader at the libraries that
# travel with the tree so it works from any path, on any machine.
export LD_LIBRARY_PATH="$GGML/build-cuda/ggml/src:$GGML/build-cuda/ggml/src/ggml-cuda:$ROOT/cuda-libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

cd "$GGML" || exit 1

VOICES=()
[ -d gguf/voices ] && VOICES=(--tts-default-voices-dir gguf/voices)

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
