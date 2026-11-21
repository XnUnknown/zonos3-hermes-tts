<#
    Zonos3 TTS for Hermes  (the Zonos equivalent of kokoro_say.py)

    A command-provider bridge: Hermes writes the text to a temp file and calls this,
    it gets WAV bytes back from the local Zonos3 server and writes them out. If the
    server is not running it launches it in WSL first (hidden, no console flash).

    Hermes config (config.yaml):
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

    Direct use:
      powershell -File zonos3_say.ps1 -TextFile in.txt -Out out.wav
      powershell -File zonos3_say.ps1 -TextFile in.txt -Out out.wav -Voice default_f76cf78a50cf8496
#>

param(
    [Parameter(Mandatory = $true)][string]$TextFile,
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$Voice = "",
    # Name of the reference voice shipped in the bundle's voices/ folder. The bridge
    # resolves it to a live speaker id at call time, so ids can change per machine.
    [string]$VoiceName = "Augusta_Thoughts_I",
    # Speech pace. 1.0 = natural. Uses the model's own speaking-rate control
    # (utf-8 bytes per second), not time stretching, so prosody stays intact.
    [double]$Speed = 1.0,
    # Measured natural pace of this voice, in bytes per second. Only matters when
    # -Speed is not 1.0; override if the pace feels off.
    [double]$BaseRate = 16.25,
    [int]$Port = 1919,
    [string]$Distro = "Ubuntu",
    # WSL path of the bundle. Empty = the folder this script's WSL twin lives in
    [string]$Root = "",
    [switch]$NoSpawn
)

$ErrorActionPreference = "Stop"
$base = "http://127.0.0.1:$Port"

function Test-Health {
    try {
        $r = Invoke-RestMethod -Uri "$base/v2/health" -TimeoutSec 2
        return ($r.status -eq "ok")
    } catch {
        return $false
    }
}

if (-not (Test-Path -LiteralPath $TextFile)) {
    Write-Error "input text file not found: $TextFile"
    exit 2
}

$text = (Get-Content -Raw -LiteralPath $TextFile).Trim()
if ([string]::IsNullOrWhiteSpace($text)) {
    Write-Error "empty input text"
    exit 2
}

# start the server in WSL if it is not answering
if (-not (Test-Health)) {
    if ($NoSpawn) {
        Write-Error "zonos3-server is not running on port $Port"
        exit 3
    }

    $cmd = "bash `$HOME/zonos3_server.sh"
    if ($Root -ne "") { $cmd = "ZONOS_ROOT='$Root' bash `$HOME/zonos3_server.sh" }
    if ($Port -ne 1919) { $cmd = "ZONOS_PORT=$Port " + $cmd }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "wsl.exe"
    $psi.Arguments = "-d $Distro -- bash -lc `"$cmd`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    [System.Diagnostics.Process]::Start($psi) | Out-Null

    $ok = $false
    for ($i = 0; $i -lt 180; $i++) {
        if (Test-Health) { $ok = $true; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $ok) {
        Write-Error "server did not become healthy on port $Port (see ~/zonos3-server.log in WSL)"
        exit 4
    }
}

$body = @{ model = "zonos3"; input = $text; response_format = "wav" }
$v = if ($Voice) { $Voice.Trim() } else { "" }

if ($v -ne "" -and $v -ne "default") {
    # explicit speaker id, e.g. default_e9c4db8a505f1201
    $body.voice = $v
    # without this the server tries raw-reference cloning and demands extra encoders
    $body.speaker_mode = "embedding"
} elseif ($VoiceName) {
    # resolve the bundled reference voice by name, since the id is machine generated
    try {
        $speakers = (Invoke-RestMethod -Uri "$base/v2/speakers" -TimeoutSec 8).speakers
        $hit = $speakers | Where-Object {
            $_.original_name -and ($_.original_name -like "$VoiceName*")
        } | Select-Object -First 1
        if (-not $hit) {
            $pretty = ($VoiceName -replace '[_\-]+', ' ')
            $hit = $speakers | Where-Object { $_.label -eq $pretty } | Select-Object -First 1
        }
        if (-not $hit) {
            $hit = $speakers | Where-Object { $_.is_default } | Select-Object -First 1
        }
        if ($hit) {
            $body.voice = $hit.id
            # force embedding cloning: raw-reference mode needs zac-encoder + ssl-teacher
            $body.speaker_mode = "embedding"
            Write-Verbose "voice: $($hit.label) ($($hit.id))"
        }
    } catch {
        Write-Verbose "could not resolve voice '$VoiceName', using server default"
    }
}

if ($Speed -ne 1.0 -and $Speed -gt 0) {
    # the model takes pace as bytes/second; BaseRate is this voice's natural pace
    $body.condition_values = @{ speaking_rate = [math]::Round($BaseRate * $Speed, 3) }
}

$json = $body | ConvertTo-Json -Compress
try {
    Invoke-WebRequest -Uri "$base/v1/audio/speech" -Method Post -ContentType "application/json" `
        -Body $json -OutFile $Out -TimeoutSec 600 | Out-Null
} catch {
    Write-Error "speech request failed: $($_.Exception.Message)"
    exit 5
}

if (-not (Test-Path -LiteralPath $Out)) {
    Write-Error "no audio written to $Out"
    exit 6
}
$len = (Get-Item -LiteralPath $Out).Length
if ($len -lt 1000) {
    Write-Error "audio looks empty ($len bytes)"
    exit 7
}

Write-Host "zonos3 wav written ($len bytes) -> $Out"
exit 0
