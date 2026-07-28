# Control Claude Code voice summaries.
# Usage: voice on | voice off | voice (toggles) | voice status
#        voice level        (show current detail level)
#        voice level 1|2|3  (1 = one-liner, 2 = medium digest, 3 = full response)
param(
    [ValidateSet('on', 'off', 'toggle', 'status', 'level')][string]$State = 'toggle',
    [string]$Value
)

$TtsDir  = $PSScriptRoot
$Flag    = Join-Path $TtsDir 'voice.off'
$LevelF  = Join-Path $TtsDir 'voice.level'

# machine-local config from untracked .env (see .env.example)
$DotEnv = @{}
$envFile = Join-Path $TtsDir '.env'
if (Test-Path $envFile) {
    foreach ($line in Get-Content $envFile) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            $DotEnv[$Matches[1]] = $Matches[2].Trim().Trim('"')
        }
    }
}
$TtsHost = if ($DotEnv['TTS_HOST']) { $DotEnv['TTS_HOST'] } else { '127.0.0.1' }
$TtsPort = if ($DotEnv['TTS_PORT']) { $DotEnv['TTS_PORT'] } else { '8880' }
$BaseUrl = "http://${TtsHost}:${TtsPort}"

$levelNames = @{ 1 = '1 (one-liner)'; 2 = '2 (medium digest)'; 3 = '3 (full response)' }
function Get-Level {
    if (Test-Path $LevelF) {
        $v = [int]((Get-Content $LevelF -ErrorAction SilentlyContinue | Select-Object -First 1))
        if ($v -ge 1 -and $v -le 3) { return $v }
    }
    return 1
}
function Speak($text) {
    try {
        $body = @{ text = $text } | ConvertTo-Json
        Invoke-RestMethod -Uri "$BaseUrl/speak" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 3 | Out-Null
    } catch {}
}

$isOff = Test-Path $Flag
if ($State -eq 'toggle') { $State = if ($isOff) { 'on' } else { 'off' } }

switch ($State) {
    'status' {
        "Voice: $(if ($isOff) { 'OFF' } else { 'ON' }) | Detail level: $($levelNames[(Get-Level)])"
    }
    'level' {
        if ($Value -match '^[123]$') {
            Set-Content $LevelF $Value
            "Detail level: $($levelNames[[int]$Value])"
            if (-not $isOff) { Speak "Detail level set to $Value" }
        } else {
            "Detail level: $($levelNames[(Get-Level)])"
            "Usage: voice level 1|2|3   (1 = one-liner, 2 = medium digest, 3 = full response)"
        }
    }
    'on' {
        Remove-Item $Flag -Force -ErrorAction SilentlyContinue
        'Voice: ON'
        Speak 'Voice is back on.'
    }
    'off' {
        New-Item -ItemType File -Path $Flag -Force | Out-Null
        try { Invoke-RestMethod -Uri "$BaseUrl/stop" -Method Post -TimeoutSec 2 | Out-Null } catch {}
        'Voice: OFF'
    }
}
