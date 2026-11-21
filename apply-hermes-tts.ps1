<#
    Patches a Hermes config.yaml so its TTS provider becomes ZONOS3-Mini.

    It backs the file up first, then replaces the whole top-level `tts:` block
    (everything from `tts:` up to the next top-level key) with the Zonos block.
    Every other setting in the file is left exactly as it was.

    Usage:
      powershell -NoProfile -ExecutionPolicy Bypass -File apply-hermes-tts.ps1
      powershell -NoProfile -ExecutionPolicy Bypass -File apply-hermes-tts.ps1 `
          -Bridge "D:\TTS\hermes\zonos_say.ps1" -Voice "default_f76cf78a50cf8496"

    Add -WhatIf to see the result without touching the file.
#>

param(
    [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA "hermes\config.yaml"),
    [string]$Bridge = (Join-Path $PSScriptRoot "zonos3_say.ps1"),
    [string]$Voice = "",
    [int]$Port = 1919,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Error "config not found: $ConfigPath (pass -ConfigPath if Hermes lives elsewhere)"
    exit 1
}
if (-not (Test-Path -LiteralPath $Bridge)) {
    Write-Error "bridge script not found: $Bridge (pass -Bridge with the real path)"
    exit 1
}

$bridgeArg = if ($Port -ne 1919) { " -Port $Port" } else { "" }

$block = @(
    "tts:"
    "  provider: zonos3"
    "  providers:"
    "    zonos3:"
    "      type: command"
    "      command: 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$Bridge`" -TextFile `"{input_path}`" -Out `"{output_path}`" -Voice `"{voice}`"$bridgeArg'"
    "      output_format: wav"
    "      voice_compatible: true"
    "      timeout: 600"
    "      max_text_length: 5000"
    "      voice: '$Voice'"
)

$raw = Get-Content -Raw -LiteralPath $ConfigPath
$nl = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
$lines = [System.Collections.ArrayList]::new()
foreach ($l in ($raw -split "`r?`n")) { [void]$lines.Add($l) }

$start = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^tts:\s*$') { $start = $i; break }
}

if ($start -ge 0) {
    $end = $lines.Count
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        # a non-indented, non-comment line starts the next top-level key
        if ($lines[$i] -match '^[^\s#]') { $end = $i; break }
    }
    $before = if ($start -gt 0) { $lines[0..($start - 1)] } else { @() }
    $after = if ($end -lt $lines.Count) { $lines[$end..($lines.Count - 1)] } else { @() }
    $new = @($before) + $block + @($after)
    Write-Host "replacing existing tts: block (lines $($start + 1)-$end)"
} else {
    $new = @($lines) + $block
    Write-Host "no tts: block found, appending one"
}

$text = ($new -join $nl)
if ($text -notmatch "`n$") { $text += $nl }

if ($WhatIf) {
    Write-Host "--- would write ---"
    Write-Host $text
    exit 0
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = "$ConfigPath.bak-$stamp"
Copy-Item -LiteralPath $ConfigPath -Destination $backup -Force
Write-Host "backup: $backup"

[System.IO.File]::WriteAllText($ConfigPath, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "updated: $ConfigPath"
Write-Host "restart Hermes, then the TTS tool will speak with Zonos."
Write-Host "to undo: Copy-Item `"$backup`" `"$ConfigPath`" -Force"
