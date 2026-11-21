# Zonos3 TTS bundle

Everything needed to run the Zonos3 speech server locally, minus the model weights. The
server downloads those itself on the first run. Nothing here needs compiling, and there is no
Python environment to create.

```
zonos3_server.sh        start / stop / status / fetch   (the server)
zonos3_say.ps1          bridge Hermes calls for TTS     (Windows side)
apply-hermes-tts.ps1    edits Hermes config.yaml for you (optional)
servers/ggml/build-cuda/  the compiled CUDA server
cuda-libs/                CUDA 12.4 runtime libraries it links against
model/                    a few paths the server reads
voices/                   the reference voice this setup always uses
```

## Requirements

- Windows 10/11 with **WSL2** and an NVIDIA GPU. The normal Windows NVIDIA driver is enough.
- WSL distro **Ubuntu 26.04**. The binary links glibc 2.43; Ubuntu 24.04 (glibc 2.39) fails with
  `version 'GLIBC_2.43' not found`. `wsl --install -d Ubuntu-26.04` if needed.
- About 4 GB free disk in WSL, 1.7 GB free VRAM while running.

## 1. Unzip inside WSL

Put the zip where Windows can see it (e.g. `D:\`), then:

```bash
mkdir -p ~/zonos3 && cd ~/zonos3
python3 -m zipfile -e /mnt/d/zonos3-tts-bundle.zip .
chmod +x zonos3_server.sh servers/ggml/build-cuda/zonos3-server
```

`python3 -m zipfile` is used because a fresh WSL distro usually has no `unzip`. If yours does,
`unzip -o /mnt/d/zonos3-tts-bundle.zip` behaves the same.

## 2. Start it

```bash
bash ~/zonos3/zonos3_server.sh
```

First run downloads about 1.1 GB of weights from Hugging Face (public, no token), then prints
`ready: http://127.0.0.1:1919` and returns your prompt. The server keeps running in the
background; there is no terminal to babysit.

```bash
bash ~/zonos3/zonos3_server.sh status    # health
bash ~/zonos3/zonos3_server.sh stop      # frees the VRAM
bash ~/zonos3/zonos3_server.sh fetch     # only download weights
```

From Windows: `curl.exe http://127.0.0.1:1919/v2/health` should return `{"status":"ok"}`.
WSL2 forwards localhost, so nothing to configure.

## 3. The voice

`voices/Augustas_Thoughts_I.wav` is loaded as the server's default voice, and `zonos3_say.ps1`
always asks for it by name, so every line you generate comes out in that voice.

Confirm it is registered:

```powershell
curl.exe http://127.0.0.1:1919/v2/speakers
```

You should see one speaker with `original_name` starting `Augusta_Thoughts_I`. The `id` next to
it is generated per machine, which is why the bridge looks the voice up by filename instead of
hardcoding an id.

To use a different reference clip, drop another `.wav` into `voices/`, restart the server, and
run the bridge with `-VoiceName "YourFile"`. To bypass the reference entirely and let the server
pick, pass `-VoiceName ""`.

Clip notes: 44.1 kHz mono WAV, 5 to 60 seconds, one speaker, no music. Anything else gets
resampled or rejected by the encoder.

If you call the API yourself, remember `"speaker_mode": "embedding"` alongside the voice id.
Without it the server assumes raw-reference cloning and answers
`reference-mode cloning of audio requires zac-encoder.gguf and ssl-teacher.gguf`. The bridge
sets it for you.

## 4. Wire it into Hermes

Copy `zonos3_say.ps1` to a permanent Windows path, for example `C:\Tools\zonos\`, then add:

```yaml
tts:
  provider: zonos3
  providers:
    zonos3:
      type: command
      command: 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Tools\zonos\zonos3_say.ps1" -TextFile "{input_path}" -Out "{output_path}" -Voice "{voice}"'
      output_format: wav
      voice_compatible: true
      timeout: 600
      max_text_length: 5000
      voice: ''
```

Leave `voice:` empty. The bridge resolves the bundled reference voice on its own; a value there
would override it with a raw speaker id.

Or run the helper, which backs the file up first and prints its own undo line:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Tools\zonos\apply-hermes-tts.ps1"
```

If Hermes lives somewhere unusual, point the helper at it:
`-ConfigPath "D:\path\to\hermes\config.yaml"`.

Restart Hermes. `voice_compatible: true` is what makes Telegram deliver a voice bubble instead
of a file.

`zonos3_say.ps1` also starts the server through `wsl.exe` if it is not running, so you can
`stop` it between sessions and it comes back by itself.

## 5. Keep it running from Windows startup (optional)

`zonos3-autostart.vbs` starts the server at logon with no console window and no terminal left
open. Put it here:

1. Press `Win+R`, type `shell:startup`, press Enter.
2. Drop `zonos3-autostart.vbs` into the folder that opens
   (`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup`).

That is all. It runs `wsl.exe` hidden, which starts the WSL distro and the server together, and
the server script exits immediately if the server is already up, so running it twice is harmless.
The server itself does not need a terminal.

To check it worked, reboot or log out and back in, then:

```powershell
curl.exe http://127.0.0.1:1919/v2/health
```

If you would rather not run it at startup, skip this: `zonos3_say.ps1` starts the server on
demand the first time Hermes asks for speech.

## Notes

- Never run `servers/ggml/build-cuda/zonos3-server` by hand. It was compiled with a RUNPATH
  pointing at the builder's home directory; `zonos3_server.sh` sets `LD_LIBRARY_PATH` to the
  bundled libraries. Running it directly gives
  `libcudart.so.12: cannot open shared object file`.
- The model stays in VRAM for as long as the server runs, about 1.65 GB measured on an RTX 3050.
  Requests never reload it.
- Output is 44.1 kHz mono WAV, about 1.1 s to render 3 s of speech once warm.
- This backend is OpenAI-compatible but rejects `speed` with 422, so the bridge never sends it.
- Logs: `~/zonos3-server.log`
