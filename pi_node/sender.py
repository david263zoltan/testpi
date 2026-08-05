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
    <h1>🛰️ Jarvis Node v7.0</h1>
    
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

# --- INTELLIGENS KINECT ADATFOLYAM ---

def check_usb_devices():
    """Megvizsgálja, hogy a Kinect melyik része van bedugva az USB-re"""
    try:
        lsusb = subprocess.check_output("lsusb", shell=True).decode("utf-8")
        cam_present = "045e:02ae" in lsusb
        audio_bootloader = "045e:02ad" in lsusb
        audio_ready = "045e:02be" in lsusb or "045e:02bf" in lsusb
        return cam_present, audio_bootloader, audio_ready
    except:
        return False, False, False

def streamer_loop():
    ctx = zmq.Context()
    p = pyaudio.PyAudio()
    audio_stream = None
    socket = None

    def create_socket():
        cfg = load_config()
        s = ctx.socket(zmq.PUB)
        s.connect(f"tcp://{cfg['pc_ip']}:{cfg['port']}")
        return s

    socket = create_socket()
    print("[STREAM] Adatküldő üzemkész...")

    last_usb_check = 0
    cam_ok = False
    audio_bootloader = False
    audio_ok = False

    while True:
        cfg = load_config()
        now = time.time()

        # 1. IP VÁLTÁS
        if reconnect_event.is_set():
            socket.close()
            socket = create_socket()
            reconnect_event.clear()

        # 2. USB HARDVER ÉSZLELÉS (3 másodpercenként)
        if now - last_usb_check > 3.0:
            cam_ok, audio_bootloader, audio_ok = check_usb_devices()
            last_usb_check = now

            # Ha látja a Bootloadert (02ad), AZONNAL feltölti a firmware-t!
            if audio_bootloader and not audio_ok:
                print("[KINECT ÉSZLELVE] Audio Bootloader megtalálva! Firmware feltöltése...")
                try:
                    subprocess.run(["sudo", "/usr/local/bin/kinect_upload_fw", "/lib/firmware/kinect/UACFirmware"], check=False)
                    time.sleep(1)
                except: pass

        # 3. KAMERA STREAM (Csak ha a kamera fizikai USB-n észlelve van!)
        if cfg['video_active'] and cam_ok:
            try:
                v_data = freenect.sync_get_video()
                d_data = freenect.sync_get_depth()
                if v_data and d_data:
                    _, img_enc = cv2.imencode('.jpg', v_data[0], [cv2.IMWRITE_JPEG_QUALITY, 70])
                    socket.send_multipart([b"video", img_enc.tobytes()])
                    socket.send_multipart([b"depth", d_data[0].tobytes()])
            except Exception as e:
                # Ha véletlenül kirepül az USB, nem spameljük a képernyőt
                cam_ok = False
                time.sleep(0.5)

        # 4. MIKROFON STREAM (Csak ha az audió hardver kész és aktív!)
        if cfg['audio_active'] and audio_ok:
            if audio_stream is None:
                try:
                    audio_stream = p.open(format=pyaudio.paInt16, channels=1, rate=16000, input=True, frames_per_buffer=1024)
                    print("[AUDIO ÉSZLELVE] Mikrofon megnyitva.")
                except:
                    audio_stream = None

            if audio_stream is not None:
                try:
                    audio_data = audio_stream.read(1024, exception_on_overflow=False)
                    socket.send_multipart([b"audio", audio_data])
                except:
                    audio_stream = None
        else:
            audio_stream = None

        # Ha nincs bedugva Kinect, csendben pihenünk (0% CPU, 0 hibaüzenet)
        if not cam_ok and not audio_bootloader:
            time.sleep(0.5)

        time.sleep(0.01)

if __name__ == "__main__":
    threading.Thread(target=run_web_server, daemon=True).start()
    streamer_loop()
