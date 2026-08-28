# Control Claude Code voice summaries.
# Usage: voice on | voice off | voice (toggles) | voice status
#        voice level        (show current detail level)
#        voice level 1|2|3  (1 = one-liner, 2 = medium digest, 3 = full response)
#        voice replay       (replay the last spoken clip)
#        voice read <path>  (read a file's contents aloud, markdown stripped)
param(
    [ValidateSet('on', 'off', 'toggle', 'status', 'level', 'replay', 'read')][string]$State = 'toggle',
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
        # send UTF-8 bytes so multi-byte chars (emoji, em-dash, accents) survive —
        # a string body lets Content-Length disagree with the actual byte count
        $json  = @{ text = $text } | ConvertTo-Json
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        Invoke-RestMethod -Uri "$BaseUrl/speak" -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 3 | Out-Null
    } catch {}
}

# strip markdown so file contents read naturally as speech (mirrors the hook)
function Clean-ForSpeech([string]$t) {
    $t = $t -replace '(?s)```.*?```', ' (code omitted) '
    $t = $t -replace '`([^`]*)`', '$1'
    $t = $t -replace '\[([^\]]*)\]\([^)]*\)', '$1'        # markdown links -> their text
    $t = $t -replace '(?m)^\s*\|.*\|\s*$', ''             # table rows
    $t = $t -replace '(?m)^#{1,6}\s*', ''                 # headers
    $t = $t -replace '(?m)^\s*[-*+]\s+', ''               # bullets
    $t = $t -replace '\*\*([^*]+)\*\*', '$1' -replace '\*([^*]+)\*', '$1'
    $t = $t -replace 'https?://\S+', 'link'
    return ($t -replace '\s{2,}', ' ').Trim()
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
    'replay' {
        try {
            $r = Invoke-RestMethod -Uri "$BaseUrl/replay" -Method Post -TimeoutSec 5
            if ($r.status -eq 'replaying') { 'Replaying last clip.' } else { 'Nothing to replay yet.' }
        } catch {
            'Nothing to replay yet.'
        }
    }
    'read' {
        if (-not $Value) { 'Usage: voice read <path-to-file>'; break }
        if ($isOff) { 'Voice is OFF — turn it on first with: voice on'; break }
        $path = $Value.Trim('"')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { "File not found: $path"; break }
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
        if (-not $raw -or -not $raw.Trim()) { "File is empty: $path"; break }
        $text = Clean-ForSpeech $raw
        $truncated = $false
        if ($text.Length -gt 6000) { $text = $text.Substring(0, 6000); $truncated = $true }
        Speak $text
        $name = Split-Path -Leaf $path
        if ($truncated) { "Reading $name (truncated to 6000 characters)." } else { "Reading $name." }
    }
}
