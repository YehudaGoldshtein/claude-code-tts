"""Kokoro TTS server for Claude Code voice summaries.

Keeps the Kokoro ONNX model warm, synthesizes speech to a WAV file, and opens
that file in an external media player so you get pause / seek / stop controls.
A single player window is reused: each new clip terminates the previous player
before launching a fresh one.

Endpoints:
  POST /speak  {"text": "...", "voice": "af_heart", "speed": 1.0}
  POST /stop   - close the current player window
  POST /replay - replay the most recently spoken clip
  GET  /health - liveness check

Logs go to logs/server.log with rotation (see LOG_* below).
"""

import json
import logging
import os
import queue
import shlex
import shutil
import subprocess
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from logging.handlers import RotatingFileHandler
from pathlib import Path

import numpy as np
from kokoro_onnx import Kokoro

DIR = Path(__file__).parent
# Last synthesized clip persisted to disk so /replay survives a server restart
CACHE_WAV = DIR / "last.wav"

# --- logging (rotating, local) ------------------------------------------------
LOG_DIR = DIR / "logs"
LOG_DIR.mkdir(exist_ok=True)
LOG_MAX_BYTES = 512 * 1024   # rotate at 512 KB
LOG_BACKUPS = 3              # keep server.log + 3 rotated copies

logger = logging.getLogger("kokoro-tts")
logger.setLevel(logging.INFO)
_fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
_file = RotatingFileHandler(
    LOG_DIR / "server.log", maxBytes=LOG_MAX_BYTES, backupCount=LOG_BACKUPS, encoding="utf-8"
)
_file.setFormatter(_fmt)
logger.addHandler(_file)
_console = logging.StreamHandler()
_console.setFormatter(_fmt)
logger.addHandler(_console)


def _load_dotenv(path: Path) -> dict:
    """Machine-local config from untracked .env (see .env.example)."""
    env = {}
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, value = line.partition("=")
                env[key.strip()] = value.strip().strip('"')
    return env


_ENV = _load_dotenv(DIR / ".env")
HOST = _ENV.get("TTS_HOST", "127.0.0.1")
PORT = int(_ENV.get("TTS_PORT", "8880"))
DEFAULT_VOICE = _ENV.get("TTS_VOICE", "af_heart")
DEFAULT_SPEED = float(_ENV.get("TTS_SPEED", "1.0"))
# Optional explicit player command template; {file} is replaced with the WAV path.
# Blank -> auto-detect (VLC, then Windows Media Player, then the OS default).
PLAYER_TEMPLATE = _ENV.get("TTS_PLAYER", "").strip()


def _first_existing(*paths):
    return next((p for p in paths if p and Path(p).exists()), None)


_VLC = _first_existing(
    r"C:\Program Files\VideoLAN\VLC\vlc.exe",
    r"C:\Program Files (x86)\VideoLAN\VLC\vlc.exe",
) or shutil.which("vlc")
_WMPLAYER = _first_existing(
    r"C:\Program Files (x86)\Windows Media Player\wmplayer.exe",
    r"C:\Program Files\Windows Media Player\wmplayer.exe",
) or shutil.which("wmplayer")


def _player_argv(path: Path):
    """Argv for the media player, or None to fall back to the OS default handler."""
    if PLAYER_TEMPLATE:
        return shlex.split(PLAYER_TEMPLATE.replace("{file}", str(path)), posix=False)
    if _VLC:
        # audio-only, quit when the clip ends; --no-one-instance so each launch is
        # its own killable process (otherwise VLC hands off to an untracked instance)
        return [_VLC, "--no-video", "--play-and-exit", "--no-one-instance", str(path)]
    if _WMPLAYER:
        return [_WMPLAYER, str(path)]
    return None


if PLAYER_TEMPLATE:
    logger.info("player: custom template %r", PLAYER_TEMPLATE)
elif _VLC:
    logger.info("player: VLC (%s)", _VLC)
elif _WMPLAYER:
    logger.info("player: Windows Media Player (%s)", _WMPLAYER)
else:
    logger.info("player: OS default .wav handler (no stop/replace control)")

# Model is loaded in __main__ *after* the port is secured, so a duplicate server
# exits immediately instead of loading a second ~325 MB model and thrashing CPU.
kokoro = None

# --- playback (single reusable player window) ---------------------------------
_player_lock = threading.Lock()
_player_proc = None  # the currently running player process, if any/trackable


def _stop_player_locked() -> None:
    """Terminate the current player (and its children). Caller holds _player_lock."""
    global _player_proc
    if _player_proc is not None and _player_proc.poll() is None:
        try:
            # kill the whole tree — players like VLC spawn child processes
            subprocess.run(
                ["taskkill", "/F", "/T", "/PID", str(_player_proc.pid)],
                capture_output=True,
                check=False,
            )
        except Exception:  # noqa: BLE001
            logger.exception("failed to terminate player pid=%s", _player_proc.pid)
    _player_proc = None


def play_file(path: Path) -> None:
    """Open the clip in the media player, replacing any window already open."""
    global _player_proc
    argv = _player_argv(path)
    with _player_lock:
        _stop_player_locked()
        if argv is None:
            os.startfile(str(path))  # noqa: S606 - Windows default handler, untrackable
            logger.info("opened %s in OS default player", path.name)
        else:
            _player_proc = subprocess.Popen(argv)
            logger.info("launched player pid=%s for %s", _player_proc.pid, path.name)


def stop() -> None:
    with _player_lock:
        _stop_player_locked()
    logger.info("playback stopped")


def _write_wav(path: Path, samples, sample_rate: int) -> None:
    """Persist float samples (-1..1) as a 16-bit mono WAV."""
    pcm = np.clip(np.asarray(samples), -1.0, 1.0)
    pcm = (pcm * 32767.0).astype("<i2")
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(int(sample_rate))
        wf.writeframes(pcm.tobytes())


def speak(text: str, voice: str, speed: float) -> None:
    """Synthesize text to CACHE_WAV and open it in the player. Runs off-thread."""
    try:
        t0 = time.perf_counter()
        samples, sample_rate = kokoro.create(text, voice=voice, speed=speed, lang="en-us")
        dur = len(samples) / sample_rate if sample_rate else 0
        logger.info(
            "synth ok: %d chars -> %.1fs audio in %.1fs (voice=%s speed=%s)",
            len(text), dur, time.perf_counter() - t0, voice, speed,
        )
        _write_wav(CACHE_WAV, samples, sample_rate)
        play_file(CACHE_WAV)
    except Exception:  # noqa: BLE001 - never let the worker thread die silently
        logger.exception("synthesis failed for %d-char text", len(text))


def replay() -> bool:
    """Re-play the last clip from CACHE_WAV (survives a server restart)."""
    if not CACHE_WAV.exists():
        logger.info("replay requested but no cached clip")
        return False
    play_file(CACHE_WAV)
    return True


# --- request queue (one worker; serves every Claude Code session) -------------
# All /speak requests from every session funnel through a single worker so we
# never run two synthesises at once (CPU thrash) or overlap audio. Each finished
# clip replaces the player window, so the most recent speech is what you hear.
_speak_q: "queue.Queue" = queue.Queue()


def _drain_queue() -> int:
    """Discard everything still waiting to be spoken. Returns how many dropped."""
    dropped = 0
    while True:
        try:
            _speak_q.get_nowait()
            _speak_q.task_done()
            dropped += 1
        except queue.Empty:
            break
    return dropped


def _worker() -> None:
    while True:
        text, voice, speed = _speak_q.get()
        try:
            speak(text, voice, speed)
        except Exception:  # noqa: BLE001 - keep the worker alive across failures
            logger.exception("worker failed on %d-char job", len(text))
        finally:
            _speak_q.task_done()


class Handler(BaseHTTPRequestHandler):
    def _respond(self, code: int, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            self._respond(200, {"status": "ok"})
        else:
            self._respond(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/stop":
            dropped = _drain_queue()
            stop()
            self._respond(200, {"status": "stopped", "dropped": dropped})
            return
        if self.path == "/replay":
            if replay():
                self._respond(200, {"status": "replaying"})
            else:
                self._respond(404, {"error": "nothing cached to replay"})
            return
        if self.path != "/speak":
            self._respond(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) or b"{}"
            # decode defensively: clients may mis-set Content-Length on multi-byte text
            payload = json.loads(raw.decode("utf-8", "replace"))
            text = (payload.get("text") or "").strip()
            if not text:
                self._respond(400, {"error": "no text"})
                return
            voice = payload.get("voice", DEFAULT_VOICE)
            speed = float(payload.get("speed", DEFAULT_SPEED))
            # hand off to the single worker so sessions never synth concurrently
            _speak_q.put((text, voice, speed))
            logger.info("/speak queued: %d chars (%d waiting)", len(text), _speak_q.qsize())
            self._respond(200, {"status": "queued", "queued": _speak_q.qsize()})
        except Exception as e:  # noqa: BLE001
            logger.exception("/speak request failed")
            self._respond(500, {"error": str(e)})

    def log_message(self, *args):  # silence stdlib request logging (we use our logger)
        pass


class _SingleServer(ThreadingHTTPServer):
    # do NOT reuse the address: a second instance must fail to bind and exit,
    # rather than co-binding the port (which on Windows causes two live servers)
    allow_reuse_address = False


if __name__ == "__main__":
    # Secure the port FIRST. If another server already owns it, exit before
    # loading a second ~325 MB model. This is the single-instance guarantee.
    try:
        httpd = _SingleServer((HOST, PORT), Handler)
    except OSError as e:
        logger.warning("port %s:%s already in use (%s) — another server is running; exiting", HOST, PORT, e)
        raise SystemExit(0)

    logger.info("Loading Kokoro model...")
    kokoro = Kokoro(str(DIR / "kokoro-v1.0.onnx"), str(DIR / "voices-v1.0.bin"))
    logger.info("Model loaded.")

    threading.Thread(target=_worker, daemon=True).start()
    logger.info("Kokoro TTS server on http://%s:%s (single worker ready)", HOST, PORT)
    httpd.serve_forever()
