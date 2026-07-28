"""Kokoro TTS server for Claude Code voice summaries.

Keeps the Kokoro ONNX model warm and plays synthesized speech locally.
Endpoints:
  POST /speak  {"text": "...", "voice": "af_heart", "speed": 1.0}
  POST /stop   - stop current playback immediately
  GET  /health - liveness check
"""

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import sounddevice as sd
from kokoro_onnx import Kokoro

DIR = Path(__file__).parent


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


def speak(text: str, voice: str, speed: float) -> None:
    samples, sample_rate = kokoro.create(text, voice=voice, speed=speed, lang="en-us")
    with play_lock:
        sd.stop()
        sd.play(samples, sample_rate)


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
