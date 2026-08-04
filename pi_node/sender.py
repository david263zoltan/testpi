import freenect
import zmq
import cv2
import numpy as np
import pyaudio
import time
import json
import os
import subprocess
import threading
from flask import Flask, request, render_template_string, redirect

# --- KONFIGURÁCIÓ KEZELÉSE ---
CONFIG_FILE = "config.json"
reconnect_event = threading.Event()

def load_config():
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r") as f:
                cfg = json.load(f)
                cfg.setdefault("pc_ip", "192.168.1.140")
                cfg.setdefault("port", 5555)
                cfg.setdefault("video_active", True)
                cfg.setdefault("audio_active", True)
                return cfg
        except: pass
    return {"pc_ip": "192.168.1.140", "port": 5555, "video_active": True, "audio_active": True}

def save_config(data):
    with open(CONFIG_FILE, "w") as f:
        json.dump(data, f, indent=4)
    reconnect_event.set()

# --- FLASK WEBADMIN ---
app = Flask(__name__)

HTML_UI = """
<!DOCTYPE html>
<html>
<head>
    <title>Jarvis Node Control</title>
    <style>
        body { font-family: 'Segoe UI', sans-serif; background: #121212; color: white; text-align: center; padding: 20px; }
        .card { background: #1e1e1e; padding: 20px; border-radius: 15px; display: inline-block; border: 1px solid #00adb5; min-width: 300px; margin: 10px; }
        input[type=text] { padding: 10px; border-radius: 5px; border: 1px solid #333; background: #000; color: white; width: 200px; }
        .btn { padding: 10px 20px; border-radius: 5px; border: none; font-weight: bold; cursor: pointer; text-decoration: none; display: inline-block; margin: 10px; color: black; }
        .btn-save { background: #00adb5; }
        .btn-on { background: #28a745; color: white; }
        .btn-off { background: #dc3545; color: white; }
        .status-box { margin-top: 15px; padding: 10px; border-radius: 5px; background: #222; font-size: 0.9em; }
    </style>
</head>
<body>
    <h1>🛰️ Jarvis Node v6.7</h1>
    
    <div class="card">
        <h3>Hálózati Beállítások</h3>
        <form action="/save_ip" method="post">
            <input type="text" name="pc_ip" value="{{ config.pc_ip }}">
            <button type="submit" class="btn btn-save">IP Mentése</button>
        </form>
    </div>

    <br>

    <div class="card">
        <h3>Stream Vezérlés</h3>
        
        <div>
            <span>📹 Videó & Mélység: </span>
            <a href="/toggle/video" class="btn {{ 'btn-on' if config.video_active else 'btn-off' }}">
                {{ 'AKTÍV' if config.video_active else 'KIKAPCSOLVA' }}
            </a>
        </div>

        <div>
            <span>🎙️ Audió (Mikrofon): </span>
            <a href="/toggle/audio" class="btn {{ 'btn-on' if config.audio_active else 'btn-off' }}">
                {{ 'AKTÍV' if config.audio_active else 'KIKAPCSOLVA' }}
            </a>
        </div>
    </div>

    <div class="status-box">
        PC Kapcsolat: tcp://{{ config.pc_ip }}:{{ config.port }}
    </div>
</body>
</html>
"""

@app.route('/')
def index():
    return render_template_string(HTML_UI, config=load_config())

@app.route('/save_ip', methods=['POST'])
def save_ip():
    config = load_config()
    config['pc_ip'] = request.form.get('pc_ip')
    save_config(config)
    return redirect('/')

@app.route('/toggle/<stream_type>')
def toggle_stream(stream_type):
    config = load_config()
    if stream_type == "video":
        config['video_active'] = not config['video_active']
    elif stream_type == "audio":
        config['audio_active'] = not config['audio_active']
    save_config(config)
    return redirect('/')

def run_web_server():
    app.run(host='0.0.0.0', port=5000, debug=False, use_reloader=False)

# --- KINECT ADATFOLYAM ---

def streamer_loop():
    # 1. Firmware feltöltés
    try:
        subprocess.run(["sudo", "/usr/local/bin/kinect_upload_fw", "/lib/firmware/kinect/UACFirmware"], check=False)
        time.sleep(1) # Várunk, hogy az ALSA regisztrálja a kártyát
    except: pass

    ctx = zmq.Context()
    p = pyaudio.PyAudio()
    audio_stream = None

    def get_audio_stream():
        """Hibatűrő mikrofon nyitás"""
        try:
            return p.open(format=pyaudio.paInt16, channels=1, rate=16000, input=True, frames_per_buffer=1024)
        except Exception as err:
            print(f"[AUDIO WARNING] Mikrofon nem érhető el: {err}")
            return None

    def create_socket():
        cfg = load_config()
        s = ctx.socket(zmq.PUB)
        s.connect(f"tcp://{cfg['pc_ip']}:{cfg['port']}")
        return s

    socket = create_socket()
    print("[STREAM] Adatküldő üzemkész...")

    while True:
        cfg = load_config()

        if reconnect_event.is_set():
            socket.close()
            socket = create_socket()
            reconnect_event.clear()

        # Megpróbáljuk megnyitni a mikrofont, ha aktív, de még nincs megnyitva
        if cfg['audio_active'] and audio_stream is None:
            audio_stream = get_audio_stream()

        try:
            # --- VIDEÓ RÉSZ ---
            if cfg['video_active']:
                try:
                    v_data = freenect.sync_get_video()
                    d_data = freenect.sync_get_depth()
                    if v_data and d_data:
                        _, img_enc = cv2.imencode('.jpg', v_data[0], [cv2.IMWRITE_JPEG_QUALITY, 70])
                        socket.send_multipart([b"video", img_enc.tobytes()])
                        socket.send_multipart([b"depth", d_data[0].tobytes()])
                except Exception as v_err:
                    print(f"[VIDEO ERROR] Kinect videó hiba: {v_err}")

            # --- AUDIÓ RÉSZ ---
            if cfg['audio_active'] and audio_stream is not None:
                try:
                    audio_data = audio_stream.read(1024, exception_on_overflow=False)
                    socket.send_multipart([b"audio", audio_data])
                except Exception as a_err:
                    print(f"[AUDIO ERROR] Mikrofon olvasási hiba: {a_err}")
                    audio_stream = None # Ha megszakad, újrapróbáljuk a következő körben

            if not cfg['video_active'] and not cfg['audio_active']:
                time.sleep(0.5)

        except Exception as e:
            print(f"[ERROR] Stream hiba: {e}")
            time.sleep(1)

        time.sleep(0.01)

if __name__ == "__main__":
    threading.Thread(target=run_web_server, daemon=True).start()
    streamer_loop()
