# One-shot installer for the Claude Code Kokoro voice-summary tool.
# Safe to re-run: every step skips work that is already done.
#
#   1. Creates .venv and installs Python dependencies
#   2. Downloads the Kokoro model files (~350 MB) if missing
#   3. Creates .env from .env.example if missing
#   4. Writes the /tts command file to ~\.claude\commands\tts.md
#   5. Merges the three hooks into ~\.claude\settings.json (backs it up first)
#   6. Prints the CLAUDE.md snippet you must add manually
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1

$ErrorActionPreference = 'Stop'
$TtsDir = $PSScriptRoot
$ClaudeDir = Join-Path $env:USERPROFILE '.claude'

Write-Host "Installing Claude voice summaries into $TtsDir" -ForegroundColor Cyan

# --- 1. Python venv + dependencies -------------------------------------------
$venvPython = Join-Path $TtsDir '.venv\Scripts\python.exe'
if (-not (Test-Path $venvPython)) {
    $python = $null
    foreach ($candidate in @('py -3', 'python')) {
        try {
            $v = Invoke-Expression "$candidate --version" 2>$null
            if ($v -match 'Python 3\.(\d+)' -and [int]$Matches[1] -ge 10) { $python = $candidate; break }
        } catch {}
    }
    if (-not $python) {
        Write-Host 'ERROR: Python 3.10+ not found. Install it first: winget install Python.Python.3.12' -ForegroundColor Red
        exit 1
    }
    Write-Host "Creating virtualenv with $python ..."
    Invoke-Expression "$python -m venv `"$TtsDir\.venv`""
}
Write-Host 'Installing Python packages (kokoro-onnx) ...'
& $venvPython -m pip install --quiet --upgrade pip
& $venvPython -m pip install --quiet kokoro-onnx
if ($LASTEXITCODE -ne 0) { Write-Host 'ERROR: pip install failed.' -ForegroundColor Red; exit 1 }

# --- 2. Model files -----------------------------------------------------------
$models = @(
    @{ Name = 'kokoro-v1.0.onnx'; Url = 'https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx' },
    @{ Name = 'voices-v1.0.bin';  Url = 'https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin' }
)
foreach ($m in $models) {
    $dest = Join-Path $TtsDir $m.Name
    if (Test-Path $dest) { Write-Host "$($m.Name) already present."; continue }
    Write-Host "Downloading $($m.Name) (this one is big, be patient) ..."
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $m.Url -OutFile $dest
}

# --- 3. .env ------------------------------------------------------------------
if (-not (Test-Path (Join-Path $TtsDir '.env'))) {
    Copy-Item (Join-Path $TtsDir '.env.example') (Join-Path $TtsDir '.env')
    Write-Host 'Created .env from .env.example (edit it to change port/voice/speed).'
}

# --- 4. /tts command ----------------------------------------------------------
$commandsDir = Join-Path $ClaudeDir 'commands'
New-Item -ItemType Directory -Force $commandsDir | Out-Null
$voicePs1 = Join-Path $TtsDir 'voice.ps1'
$ttsMd = @'
---
description: Control spoken summaries (usage: /tts, /tts on|off|status, /tts level 1|2|3, /tts replay, /tts read <path>) — note /voice is Claude Code's built-in voice-input mode
allowed-tools: Bash(powershell *), PowerShell
---

Control the local Kokoro voice-summary system. Parse the user's argument(s): `$ARGUMENTS`

- No arguments → run with no parameters (toggles on/off)
- `on` / `off` / `status` → pass as `-State <value>`
- `level` → pass `-State level`
- `level <1|2|3>` → pass `-State level -Value <n>`  (1 = one-liner, 2 = medium ~8-sentence digest, 3 = full response read aloud)
- `replay` → pass `-State replay`  (replays the last spoken clip)
- `read <path>` → pass `-State read -Value "<path>"`  (reads a file aloud, markdown stripped; quote the path)

```
powershell -NoProfile -ExecutionPolicy Bypass -File "__VOICE_PS1__" <mapped parameters>
```

Report the command's output back in one short line, nothing else.
'@
$ttsMd.Replace('__VOICE_PS1__', $voicePs1) | Set-Content -Encoding utf8 (Join-Path $commandsDir 'tts.md')
Write-Host "Wrote $commandsDir\tts.md"

# --- 5. Hooks in settings.json -------------------------------------------------
$settingsPath = Join-Path $ClaudeDir 'settings.json'
$hookPs1 = Join-Path $TtsDir 'claude-tts-hook.ps1'
$settings = if (Test-Path $settingsPath) {
    Copy-Item $settingsPath "$settingsPath.bak-tts-install"
    Get-Content $settingsPath -Raw | ConvertFrom-Json
} else { [PSCustomObject]@{} }
if (-not $settings.PSObject.Properties['hooks']) {
    $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([PSCustomObject]@{})
}

$events = @{ SessionStart = 'warm'; Stop = 'speak'; UserPromptSubmit = 'stop' }
foreach ($event in $events.Keys) {
    $cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$hookPs1`" -Mode $($events[$event])"
    $entry = [PSCustomObject]@{
        matcher = ''
        hooks   = @([PSCustomObject]@{ type = 'command'; command = $cmd; async = $true })
    }
    $existing = @()
    if ($settings.hooks.PSObject.Properties[$event]) {
        # drop any stale entry pointing at claude-tts-hook.ps1, keep everything else
        $existing = @($settings.hooks.$event | Where-Object {
            -not (@($_.hooks) | Where-Object { $_.command -like '*claude-tts-hook.ps1*' })
        })
    }
    $settings.hooks | Add-Member -NotePropertyName $event -NotePropertyValue (@($existing) + @($entry)) -Force
}
$settings | ConvertTo-Json -Depth 32 | Set-Content -Encoding utf8 $settingsPath
Write-Host "Merged hooks into $settingsPath (backup at $settingsPath.bak-tts-install)"

# --- 6. Manual step ------------------------------------------------------------
Write-Host ''
Write-Host 'DONE. One manual step remains — add this to your global CLAUDE.md' -ForegroundColor Yellow
Write-Host "($ClaudeDir\CLAUDE.md) so Claude ends every response with a speakable line:" -ForegroundColor Yellow
Write-Host ''
Write-Host '  ## Voice summary'
Write-Host '  At the very end of every response, add one final line that starts with'
Write-Host '  the speaker emoji followed by a 1-2 sentence summary of what you did,'
Write-Host '  found, or are asking. Write it for the ear: plain conversational language,'
Write-Host '  no markdown, no code, no file paths, no symbols.'
Write-Host ''
Write-Host 'Then restart Claude Code. Toggle with /tts, detail with /tts level 1|2|3.'
