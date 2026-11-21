# zonos3-hermes-tts

Run [ZONOS3-Mini](https://github.com/Zyphra/ZONOS3-Mini) as a local, GPU-resident TTS
provider for [Hermes Agent](https://hermes-agent.nousresearch.com) on Windows.

Two files, same shape as the Kokoro setup most people start with: a server that holds the
model in VRAM, and a bridge Hermes calls for each line of speech.

```
Hermes (Windows)                        WSL2 (Ubuntu 26.04)
text_to_speech
      |
      v
zonos3_say.ps1  --- POST JSON --->  127.0.0.1:1919  /v1/audio/speech
      ^                                    |
      |                                    v
      +------- WAV 44.1 kHz <-------  zonos3-server (GPU, model resident)
                                      needs: cuda-libs + build-cuda/ggml/src
```

## Files

| file | role | runs on |
|---|---|---|
| `zonos3_server.sh` | loads the model once, keeps it resident, `start` / `stop` / `status` | WSL |
| `zonos3_say.ps1` | bridge: text file in, WAV out. Starts the server if it is down | Windows |
| `apply-hermes-tts.ps1` | optional: backs up `config.yaml` and swaps in the provider block | Windows |
| `SETUP.md` | the long version, with troubleshooting | either |

## What this repo does not contain

The compiled server and the model weights live outside git, because git caps a single file at
100 MB and the weights are 1.1 GB of them:

- **weights** come from Hugging Face, public, no token: `Zyphra/ZONOS3-Mini`
- **compiled server** (`build-cuda`) and the **CUDA runtime libs** come from the maintainer as a
  tarball, or you build them yourself with `cmake -B build-cuda -DGGML_CUDA=ON`

Layout expected by the scripts:

```
~/ZONOS3-Mini/
  servers/ggml/
    build-cuda/        <- compiled server (zonos3-server + libggml*.so)
    gguf/              <- zonos3-ptq.gguf, zac-keep2.gguf, spk-encoder.gguf
  cuda-libs/           <- libcudart.so.12, libcublas.so.12, libcublasLt.so.12
```

## Requirements

- Windows 10/11 with **WSL2** and a working NVIDIA GPU (`nvidia-smi` must work inside WSL)
- WSL distro **Ubuntu 26.04**. The prebuilt server links against **glibc 2.43**. Ubuntu 24.04
  ships glibc 2.39 and fails with `version 'GLIBC_2.43' not found`. Compiling it yourself on an
  older distro is the only way around that.
- ~4 GB free disk in WSL, ~1.7 GB VRAM while the server runs

## Quick start

```powershell
# 1. server script next to the tree (it has to be in the WSL home)
wsl -d Ubuntu -- cp /mnt/d/TTS/zonos3_server.sh ~/zonos3_server.sh
wsl -d Ubuntu -- chmod +x ~/zonos3_server.sh

# 2. start and verify
wsl -d Ubuntu -- bash ~/zonos3_server.sh start
curl.exe http://127.0.0.1:1919/v2/health
```

```powershell
# 3. test the bridge
"Hermes, speak." | Out-File -Encoding utf8 $env:TEMP\z.txt
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\TTS\zonos3_say.ps1" -TextFile "$env:TEMP\z.txt" -Out "$env:TEMP\z.wav"
```

```yaml
# 4. %LOCALAPPDATA%\hermes\config.yaml
tts:
  provider: zonos3
  providers:
    zonos3:
      type: command
      command: 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "D:\TTS\zonos3_say.ps1" -TextFile "{input_path}" -Out "{output_path}" -Voice "{voice}"'
      output_format: wav
      voice_compatible: true
      timeout: 600
      max_text_length: 5000
      voice: ''
```

Restart Hermes. Keep your previous provider block so you can switch back with one line.

## Fetching the weights yourself

```bash
cd ~/ZONOS3-Mini/servers/ggml && mkdir -p gguf
base=https://huggingface.co/Zyphra/ZONOS3-Mini/resolve/main/gguf
curl -L -o gguf/zonos3-ptq.gguf  "$base/backbone-ptq.gguf"
curl -L -o gguf/zac-keep2.gguf   "$base/zac-keep2.gguf"
curl -L -o gguf/spk-encoder.gguf "$base/spk-encoder.gguf"
```

Optional default voices (cloned reference clips, about 21 MB):

```bash
pip install -U "huggingface_hub[cli]"
hf download Zyphra/ZONOS3-Mini --include 'gguf/voices/*' --local-dir .
```

## Measured behaviour (RTX 3050 Laptop, 6 GB)

| state | GPU memory used |
|---|---|
| no server | 602 MiB |
| server up, zero requests | 2273 MiB |
| during a synthesis | 2341 MiB |

The model is loaded once at startup and stays in VRAM for the lifetime of the process.
Requests never reload it. A 3 second line renders in about 1.1 second warm. Stopping the
server returns the memory immediately.

If you would rather not hold 1.7 GB all day, `stop` it and let the bridge start it on demand.
The first line then costs a few seconds of load.

## Notes

- Never launch `build-cuda/zonos3-server` directly. It was compiled with a RUNPATH pointing at
  the build machine's home directory; `zonos3_server.sh` sets `LD_LIBRARY_PATH` so it works
  anywhere. Bypassing it gives `libcudart.so.12: cannot open shared object file`.
- This server is OpenAI-compatible but rejects `speed` with 422, so the bridge never sends it.
- Logs go to `~/zonos3-server.log`.

## Two ways to get it running

**A. The bundle zip (easiest).** The maintainer publishes `zonos3-tts-bundle.zip`, about 426 MB.
It contains the compiled server, the CUDA runtime libraries, the scripts and a README. The
weights are deliberately absent: `zonos3_server.sh` downloads about 1.1 GB from Hugging Face on
first run. Unpack it inside WSL and start it, nothing else to install:

```bash
mkdir -p ~/zonos3 && cd ~/zonos3
python3 -m zipfile -e /mnt/d/zonos3-tts-bundle.zip .
chmod +x zonos3_server.sh servers/ggml/build-cuda/zonos3-server
bash zonos3_server.sh
```

(`unzip` is missing from many fresh WSL distros, hence `python3 -m zipfile`. Both work.)

**B. Assemble it yourself** from the pieces described above: clone upstream, fetch the weights
with the curl commands below, and either build `build-cuda` with cmake or get it from the
maintainer.

## Sync weights by hand

`bash zonos3_server.sh fetch` downloads only the weights and exits, useful if you want the
1.1 GB out of the way before the first voice request.

## Credits and licences

- ZONOS3-Mini code, patches and weights: [Zyphra/ZONOS3-Mini](https://github.com/Zyphra/ZONOS3-Mini),
  model files on [Hugging Face](https://huggingface.co/Zyphra/ZONOS3-Mini). This repo only
  glues them to Hermes; no upstream code is vendored here.
- `ggml` submodule and CUDA runtime libraries remain under their own licences.
- The scripts in this repo: do what you like with them.
