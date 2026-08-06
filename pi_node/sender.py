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

# --- KONFIGURÁCIÓ ---
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
        body { font-family: sans-serif; background: #121212; color: white; text-align: center; padding: 20px; }
        .card { background: #1e1e1e; padding: 20px; border-radius: 15px; display: inline-block; border: 1px solid #00adb5; min-width: 320px; }
        input { padding: 10px; border-radius: 5px; border: 1px solid #333; background: #000; color: white; margin-bottom: 10px; width: 80%; }
        .btn { padding: 12px 24px; border-radius: 5px; border: none; font-weight: bold; cursor: pointer; text-decoration: none; display: inline-block; margin: 5px; color: black; }
        .btn-save { background: #00adb5; width: 85%; }
        .btn-on { background: #28a745; color: white; }
        .btn-off { background: #dc3545; color: white; }
        .status { color: #888; font-size: 0.8em; margin-top: 15px; }
    </style>
</head>
<body>
    <div class="card">
        <h1>🛰️ Jarvis Node v8.3</h1>
        <form action="/save_ip" method="post">
            <input type="text" name="pc_ip" value="{{ config.pc_ip }}">
            <button type="submit" class="btn btn-save">IP FRISSÍTÉSE</button>
        </form>
        <hr style="border: 0.5px solid #333; margin: 20px 0;">
        <div>
            <span>📹 Videó: </span>
            <a href="/toggle/video" class="btn {{ 'btn-on' if config.video_active else 'btn-off' }}">
                {{ 'AKTÍV' if config.video_active else 'KI' }}
            </a>
        </div>
        <div>
            <span>🎙️ Audió: </span>
            <a href="/toggle/audio" class="btn {{ 'btn-on' if config.audio_active else 'btn-off' }}">
                {{ 'AKTÍV' if config.audio_active else 'KI' }}
            </a>
        </div>
        <div class="status">
            Cél: tcp://{{ config.pc_ip }}:{{ config.port }}<br>
            Firmware: Rendszerszintű (udev)
        </div>
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
    if stream_type == "video": config['video_active'] = not config['video_active']
    elif stream_type == "audio": config['audio_active'] = not config['audio_active']
    save_config(config)
    return redirect('/')

# --- ADATFOLYAM KEZELŐ ---

def check_usb_status():
    """Lusb segítségével ellenőrzi az eszköz állapotát (nem foglalja le a portot)"""
    try:
        lsusb = subprocess.check_output("lsusb", shell=True).decode("utf-8")
        cam_ready = "045e:02ae" in lsusb
        # 02be vagy 02bf jelenti, hogy a firmware sikeresen beépült
        audio_ready = "045e:02be" in lsusb or "045e:02bf" in lsusb
        return cam_ready, audio_ready
    except:
        return False, False

def streamer_loop():
    ctx = zmq.Context()
    p = pyaudio.PyAudio()
    audio_stream = None
    socket = None

    def get_socket():
        cfg = load_config()
        s = ctx.socket(zmq.PUB)
        s.setsockopt(zmq.SNDHWM, 1) # Csak a legfrissebb adatot küldjük
        s.connect(f"tcp://{cfg['pc_ip']}:{cfg['port']}")
        return s

    socket = get_socket()
    print("[SYSTEM] Node elindult, várakozás a PC-re...")

    last_check_time = 0
    cam_ok, audio_ok = False, False

    while True:
        now = time.time()
        cfg = load_config()

        # 1. IP váltás kezelése
        if reconnect_event.is_set():
            print("[SYSTEM] IP cím változott, újracsatlakozás...")
            socket.close()
            socket = get_socket()
            reconnect_event.clear()

        # 2. Hardver állapot ellenőrzése 2 másodpercenként
        if now - last_check_time > 2.0:
            cam_ok, audio_ok = check_usb_status()
            last_check_time = now

        # 3. KAMERA STREAM
        if cfg['video_active'] and cam_ok:
            try:
                # sync_get_video() -> (data, timestamp)
                v_data, _ = freenect.sync_get_video()
                d_data, _ = freenect.sync_get_depth()
                
                if v_data is not None:
                    _, img_enc = cv2.imencode('.jpg', v_data, [cv2.IMWRITE_JPEG_QUALITY, 60])
                    socket.send_multipart([b"video", img_enc.tobytes()])
                
                if d_data is not None:
                    socket.send_multipart([b"depth", d_data.tobytes()])
            except Exception:
                cam_ok = False # Ha hiba van, valószínűleg kihúzták

        # 4. AUDIO STREAM
        if cfg['audio_active'] and audio_ok:
            if audio_stream is None:
                try:
                    audio_stream = p.open(format=pyaudio.paInt16, channels=1, rate=16000, input=True, frames_per_buffer=1024)
                    print("[AUDIO] Mikrofon aktiválva.")
                except:
                    audio_stream = None
            
            if audio_stream:
                try:
                    a_data = audio_stream.read(1024, exception_on_overflow=False)
                    socket.send_multipart([b"audio", a_data])
                except:
                    audio_stream.close()
                    audio_stream = None
        else:
            # Ha kikapcsoltuk vagy eltűnt a hardver, zárjuk be a streamet
            if audio_stream:
                try: audio_stream.close()
                except: pass
                audio_stream = None

        # 5. CPU kímélés
        if not cam_ok and not audio_ok:
            time.sleep(1) # Ha semmi nincs bedugva, pihenjen a proci
        else:
            time.sleep(0.005)

if __name__ == "__main__":
    # Flask indítása külön szálon
    threading.Thread(target=lambda: app.run(host='0.0.0.0', port=5000, debug=False, use_reloader=False), daemon=True).start()
    # Adatküldés indítása a főszálon
    try:
        streamer_loop()
    except KeyboardInterrupt:
        print("\n[SYSTEM] Leállítás...")
