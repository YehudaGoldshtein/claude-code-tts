# Claude Code Voice Summaries (local Kokoro TTS)

Makes Claude Code speak a short summary of every response out loud, fully
offline, using the [Kokoro](https://github.com/thewh1teagle/kokoro-onnx) TTS
model running on your own machine. Windows only (PowerShell hooks).

How it works:

1. A snippet in your global `CLAUDE.md` asks Claude to end every response with
   a one-line spoken summary marked by a 🔊 emoji.
2. A `Stop` hook extracts that line from the transcript and POSTs it to a tiny
   local HTTP server (`server.py`) that keeps the Kokoro model warm and plays
   the audio. A `SessionStart` hook pre-warms the server; a `UserPromptSubmit`
   hook cuts off playback the moment you send a new message.
3. The `/tts` slash command toggles the voice and sets the detail level
   (1 = one-liner, 2 = ~8-sentence digest, 3 = the full response read aloud).

## Install

```powershell
git clone https://github.com/YehudaGoldshtein/claude-code-tts "$env:USERPROFILE\.claude\tts"
cd "$env:USERPROFILE\.claude\tts"
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

The clone location matters: the installer registers hooks pointing at the
scripts wherever they sit, but `~\.claude\tts` is the conventional home.

Then add the **Voice summary** snippet to your global `CLAUDE.md` (the
installer prints it) and restart Claude Code.

## What is NOT in this repo, and how to get it

The repo only tracks the small scripts. Everything below is deliberately
untracked and must exist locally — `install.ps1` takes care of all of it:

| Missing piece | Size | How to get it |
|---|---|---|
| `kokoro-v1.0.onnx` (the TTS model) | ~325 MB | Auto-downloaded by `install.ps1`, or manually from [kokoro-onnx releases](https://github.com/thewh1teagle/kokoro-onnx/releases/tag/model-files-v1.0) into this folder |
| `voices-v1.0.bin` (the voice pack) | ~27 MB | Same release page, same folder |
| `.venv/` (Python environment) | ~300 MB | `python -m venv .venv` then `.venv\Scripts\pip install kokoro-onnx sounddevice` — or just run `install.ps1` |
| `.env` (machine-local config) | — | `copy .env.example .env`, then edit port/voice/speed if you want non-defaults |
| Python 3.10+ | — | `winget install Python.Python.3.12` (prerequisite; the installer checks and tells you) |
| Hook entries in `~\.claude\settings.json` | — | Merged in by `install.ps1` (a backup of your settings is saved first) |
| `~\.claude\commands\tts.md` (the `/tts` command) | — | Written by `install.ps1` with the correct local paths |
| Voice-summary snippet in `~\.claude\CLAUDE.md` | — | Manual — the installer prints the exact text to paste |
| `voice.off` / `voice.level` (runtime state) | — | Created automatically by `/tts off` and `/tts level N` |

## Configuration

Copy `.env.example` to `.env` (untracked) and edit:

```
TTS_HOST=127.0.0.1   # where the local server binds
TTS_PORT=8880
TTS_VOICE=af_heart   # any kokoro voice: af_bella, am_adam, bf_emma, bm_george, ...
TTS_SPEED=1.0
```

All scripts fall back to these defaults when `.env` is absent.

## Usage

- `/tts` — toggle voice on/off
- `/tts status` — show state and detail level
- `/tts level 1|2|3` — one-liner / medium digest / full response
- The server starts on demand; first synthesis after a cold start takes a few
  seconds while the model loads (CPU inference).

## Files

- `server.py` — local HTTP server wrapping kokoro-onnx (`/speak`, `/stop`, `/health`)
- `claude-tts-hook.ps1` — Claude Code hook (modes: `warm`, `speak`, `stop`)
- `voice.ps1` — CLI behind the `/tts` command
- `install.ps1` — one-shot idempotent installer
- `.env.example` — template for machine-local config
