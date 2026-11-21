# Zonos3 TTS for Hermes

Two files, same shape as the Kokoro setup you already have.

| file | role | where it runs |
|---|---|---|
| `zonos3_server.sh` | the server. Loads the model once, keeps it resident, answers `POST /v1/audio/speech` on `127.0.0.1:1919` | WSL |
| `zonos3_say.ps1` | the bridge. Hermes calls it with a text file, it returns a WAV. Starts the server if it is down | Windows |
| `apply-hermes-tts.ps1` | optional. Backs up `config.yaml` and swaps in the block below for you | Windows |

Tested: server start, bridge synth from Windows (441 KB WAV), and config patching against a
real `config.yaml` with all 38 top-level keys left intact.

---

## 1. Requirements

- WSL2 with **Ubuntu 26.04** and a working NVIDIA GPU (`nvidia-smi` inside WSL must print your card)
- The ZONOS3-Mini tree already present at `~/ZONOS3-Mini` (this is the `D:\TTS\zonos3` folder,
  copied in)
- glibc 2.43 or newer. `ldd --version` tells you. Ubuntu 24.04 is 2.39 and will fail with
  `version 'GLIBC_2.43' not found`, which no amount of configuration can fix.

## 2. Put the server script next to the tree

```powershell
wsl -d Ubuntu -- cp /mnt/d/TTS/zonos3_server.sh ~/zonos3_server.sh
wsl -d Ubuntu -- chmod +x ~/zonos3_server.sh
```

`zonos3_say.ps1` launches `~/zonos3_server.sh` when needed, so it has to live in the WSL home
directory. If your tree is somewhere else, pass `-Root` to the bridge instead.

## 3. Start it

```powershell
wsl -d Ubuntu -- bash ~/zonos3_server.sh start
wsl -d Ubuntu -- bash ~/zonos3_server.sh status
wsl -d Ubuntu -- bash ~/zonos3_server.sh stop
```

It prints `ready: http://127.0.0.1:1919`. WSL2 forwards localhost, so Windows reaches that
port directly, no forwarding rules.

## 4. Test the bridge before touching Hermes

```powershell
"Hello from Zonos." | Out-File -Encoding utf8 $env:TEMP\z.txt
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\TTS\zonos3_say.ps1" -TextFile "$env:TEMP\z.txt" -Out "$env:TEMP\z.wav"
```

It prints `zonos3 wav written (N bytes)`. Play that file. If it sounds right, the rest is config.

## 5. Point Hermes at it

Edit `%LOCALAPPDATA%\hermes\config.yaml`:

```yaml
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

Or let the script do it, which backs the file up first and prints its own undo line:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\TTS\apply-hermes-tts.ps1"
```

Restart Hermes. `voice_compatible: true` is what makes Telegram deliver a voice bubble
instead of a file.

## 6. Voices

```powershell
curl.exe http://127.0.0.1:1919/v2/speakers
```

Each entry has an `id` (e.g. `default_f76cf78a50cf8496`) and a `label` (e.g. `Ananya hi F 1`).
Leave `voice: ''` for the server default, or pass one:

```powershell
powershell -File "D:\TTS\zonos3_say.ps1" -TextFile in.txt -Out out.wav -Voice default_f76cf78a50cf8496
```

---

## How it compares to Kokoro

| | Kokoro (yours now) | Zonos3 |
|---|---|---|
| server | `kokoro_server.py`, port 5123 | `zonos3_server.sh` (wraps the compiled binary), port 1919 |
| bridge | `kokoro_say.py`, HTTP `POST /tts` | `zonos3_say.ps1`, HTTP `POST /v1/audio/speech` (OpenAI-compatible) |
| audio | 24 kHz mono | 44.1 kHz mono |
| GPU use | small, model resident | ~2-3 GB VRAM resident |
| speed control | yes | no, this backend rejects `speed` with 422 |

Both are command providers, so switching between them is one line in `config.yaml`. Keep your
Kokoro block in place so you can flip back.

## Notes

- Never run `build-cuda/zonos3-server` by hand. It was compiled with a RUNPATH pointing at the
  build machine's home directory; the server script fixes the library path. Bypassing it gives
  `libcudart.so.12: cannot open shared object file`.
- Logs: `~/zonos3-server.log` in WSL.
- Stop before unplugging the GPU-heavy work, it holds VRAM the whole time it runs.
