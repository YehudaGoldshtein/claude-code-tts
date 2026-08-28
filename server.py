"""Kokoro TTS server for Claude Code voice summaries.

Keeps the Kokoro ONNX model warm and plays synthesized speech locally.
Endpoints:
  POST /speak  {"text": "...", "voice": "af_heart", "speed": 1.0}
  POST /stop   - stop current playback immediately
  POST /replay - replay the most recently spoken clip
  GET  /health - liveness check
"""

import json
import threading
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import numpy as np
import sounddevice as sd
from kokoro_onnx import Kokoro

DIR = Path(__file__).parent
# Last synthesized clip persisted to disk so /replay survives a server restart
CACHE_WAV = DIR / "last.wav"


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

print("Loading Kokoro model...")
kokoro = Kokoro(str(DIR / "kokoro-v1.0.onnx"), str(DIR / "voices-v1.0.bin"))
print("Model loaded.")

play_lock = threading.Lock()

# Cache the most recently synthesized audio so /replay can re-play it instantly
# without re-running inference. Kept in memory and mirrored to CACHE_WAV on disk
# so replay works even after the server restarts. Holds (samples, sample_rate).
last_audio = None
last_audio_lock = threading.Lock()


def _write_wav(path: Path, samples, sample_rate: int) -> None:
    """Persist float samples (-1..1) as a 16-bit mono WAV."""
    pcm = np.clip(np.asarray(samples), -1.0, 1.0)
    pcm = (pcm * 32767.0).astype("<i2")
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(int(sample_rate))
        wf.writeframes(pcm.tobytes())


def _read_wav(path: Path):
    """Load a 16-bit mono WAV back into (float samples, sample_rate)."""
    with wave.open(str(path), "rb") as wf:
        sample_rate = wf.getframerate()
        frames = wf.readframes(wf.getnframes())
    samples = np.frombuffer(frames, dtype="<i2").astype("float32") / 32767.0
    return samples, sample_rate


def speak(text: str, voice: str, speed: float) -> None:
    global last_audio
    samples, sample_rate = kokoro.create(text, voice=voice, speed=speed, lang="en-us")
    with last_audio_lock:
        last_audio = (samples, sample_rate)
    try:
        _write_wav(CACHE_WAV, samples, sample_rate)
    except Exception:  # noqa: BLE001 - disk cache is best-effort
        pass
    with play_lock:
        sd.stop()
        sd.play(samples, sample_rate)


def replay() -> bool:
    """Re-play the last clip from memory, or from disk after a restart."""
    with last_audio_lock:
        cached = last_audio
    if cached is None and CACHE_WAV.exists():
        try:
            cached = _read_wav(CACHE_WAV)
        except Exception:  # noqa: BLE001
            cached = None
    if cached is None:
        return False
    samples, sample_rate = cached
    with play_lock:
        sd.stop()
        sd.play(samples, sample_rate)
    return True


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
            sd.stop()
            self._respond(200, {"status": "stopped"})
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
            payload = json.loads(self.rfile.read(length) or b"{}")
            text = (payload.get("text") or "").strip()
            if not text:
                self._respond(400, {"error": "no text"})
                return
            voice = payload.get("voice", DEFAULT_VOICE)
            speed = float(payload.get("speed", DEFAULT_SPEED))
            # Synthesize in a worker thread so the HTTP response returns fast
            threading.Thread(target=speak, args=(text, voice, speed), daemon=True).start()
            self._respond(200, {"status": "speaking"})
        except Exception as e:  # noqa: BLE001
            self._respond(500, {"error": str(e)})

    def log_message(self, *args):  # silence request logging
        pass


if __name__ == "__main__":
    print(f"Kokoro TTS server on http://{HOST}:{PORT}")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
