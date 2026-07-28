# Claude Code voice hook: speaks the trailing voice-summary line of each response
# via the local Kokoro TTS server. Modes:
#   speak - (Stop hook) extract summary from transcript and speak it
#   stop  - (UserPromptSubmit hook) cut off any current playback
#   warm  - (SessionStart hook) make sure the TTS server is up and model loaded
param([string]$Mode = 'speak')

$ErrorActionPreference = 'SilentlyContinue'
$TtsDir = $PSScriptRoot

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
$Marker  = [char]::ConvertFromUtf32(0x1F50A)  # speaker emoji, avoids file-encoding issues

# strip markdown so prose reads naturally as speech
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

function Test-Server {
    try {
        $r = Invoke-RestMethod -Uri "$BaseUrl/health" -TimeoutSec 1
        return $r.status -eq 'ok'
    } catch { return $false }
}

function Start-Server {
    if (Test-Server) { return $true }
    $pythonw = Join-Path $TtsDir '.venv\Scripts\pythonw.exe'
    Start-Process -FilePath $pythonw -ArgumentList "`"$TtsDir\server.py`"" -WindowStyle Hidden
    # wait for model load (first start can take a while on CPU)
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-Server) { return $true }
    }
    return $false
}

switch ($Mode) {
    'warm' {
        Start-Server | Out-Null
        exit 0
    }
    'stop' {
        try { Invoke-RestMethod -Uri "$BaseUrl/stop" -Method Post -TimeoutSec 1 | Out-Null } catch {}
        exit 0
    }
    'speak' {
        # kill switch: `voice off` creates this file, `voice on` removes it
        if (Test-Path (Join-Path $TtsDir 'voice.off')) { exit 0 }
        # hook payload arrives as JSON on stdin
        $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
        $transcript = $payload.transcript_path
        if (-not $transcript -or -not (Test-Path $transcript)) { exit 0 }

        # find the last assistant message's text in the JSONL transcript
        $lastText = $null
        foreach ($line in [System.IO.File]::ReadLines($transcript)) {
            if ($line -notmatch '"assistant"') { continue }
            try { $entry = $line | ConvertFrom-Json } catch { continue }
            if ($entry.type -ne 'assistant') { continue }
            $textParts = @($entry.message.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text })
            if ($textParts.Count -gt 0) { $lastText = $textParts -join "`n" }
        }
        if (-not $lastText) { exit 0 }

        # detail level: 1 = one-liner (default), 2 = medium digest, 3 = full response
        $level = 1
        $levelFile = Join-Path $TtsDir 'voice.level'
        if (Test-Path $levelFile) {
            $v = [int]((Get-Content $levelFile -ErrorAction SilentlyContinue | Select-Object -First 1))
            if ($v -ge 1 -and $v -le 3) { $level = $v }
        }

        # the trailing voice-summary line (marked with the speaker emoji)
        $markerLine = $null
        foreach ($l in ($lastText -split "`n")) {
            $t = $l.Trim()
            if ($t.StartsWith($Marker)) { $markerLine = $t.Substring($Marker.Length).TrimStart(':',' ').Trim() }
        }
        # body text = response without the marker line
        $bodyText = (($lastText -split "`n") | Where-Object { -not $_.Trim().StartsWith($Marker) }) -join "`n"

        $summary = $null
        switch ($level) {
            1 { $summary = $markerLine }
            2 {
                # medium digest: first ~8 sentences of the cleaned response + the one-liner as closer
                $clean = Clean-ForSpeech $bodyText
                $sentences = @($clean -split '(?<=[.!?])\s+' | Where-Object { $_.Trim().Length -gt 0 })
                $take = [Math]::Min(8, $sentences.Count)
                $summary = ($sentences[0..($take - 1)] -join ' ')
                if ($markerLine) { $summary = "$summary  In short: $markerLine" }
                if ($summary.Length -gt 1600) { $summary = $summary.Substring(0, 1600) }
            }
            3 {
                # full response, cleaned for the ear (capped so CPU synthesis stays sane)
                $summary = Clean-ForSpeech $bodyText
                if ($markerLine -and -not $summary) { $summary = $markerLine }
                if ($summary.Length -gt 6000) { $summary = $summary.Substring(0, 6000) + ' ... response truncated.' }
            }
        }
        if (-not $summary) { exit 0 }

        if (-not (Start-Server)) { exit 0 }
        $body = @{ text = $summary } | ConvertTo-Json
        try {
            Invoke-RestMethod -Uri "$BaseUrl/speak" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 10 | Out-Null
        } catch {}
        exit 0
    }
}
