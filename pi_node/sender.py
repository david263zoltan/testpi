import freenect, zmq, cv2, numpy as np, pyaudio, time, json, os, subprocess, threading
from flask import Flask, request, render_template_string, redirect

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
                cfg.setdefault("depth_active", True) # ÚJ
                cfg.setdefault("audio_active", True)
                return cfg
        except: pass
    return {"pc_ip": "192.168.1.140", "port": 5555, "video_active": True, "depth_active": True, "audio_active": True}

def save_config(data):
    with open(CONFIG_FILE, "w") as f: json.dump(data, f, indent=4)
    reconnect_event.set()

app = Flask(__name__)

HTML_UI = """
<!DOCTYPE html>
<html>
<head><title>Jarvis Node</title>
<style>body{background:#121212;color:white;text-align:center;font-family:sans-serif;padding:20px;}
.card{background:#1e1e1e;padding:25px;border-radius:15px;display:inline-block;border:1px solid #00adb5;min-width:320px;}
.btn{padding:10px 20px;border-radius:5px;border:none;font-weight:bold;cursor:pointer;text-decoration:none;color:black;margin:5px;display:inline-block;width:120px;}
.btn-on{background:#28a745;color:white;}.btn-off{background:#dc3545;color:white;}
.status-led { display:inline-block; width:10px; height:10px; border-radius:50%; margin-right:5px; }
.led-on { background: #28a745; box-shadow: 0 0 5px #28a745; }
.led-off { background: #dc3545; }
</style></head>
<body><div class="card"><h1>🛰️ Jarvis Node v8.4</h1>
<form action="/save_ip" method="post">
<input type="text" name="pc_ip" value="{{ config.pc_ip }}" style="padding:8px; border-radius:5px; border:none;">
<button type="submit" style="padding:8px; background:#00adb5; border:none; border-radius:5px; cursor:pointer;">Mentés</button>
</form><hr style="border:0.5px solid #333; margin:20px 0;">
<div><span>📹 Videó: </span><a href="/toggle/video" class="btn {{ 'btn-on' if config.video_active else 'btn-off' }}">{{ 'AKTÍV' if config.video_active else 'KI' }}</a></div>
<div><span>📏 Mélység: </span><a href="/toggle/depth" class="btn {{ 'btn-on' if config.depth_active else 'btn-off' }}">{{ 'AKTÍV' if config.depth_active else 'KI' }}</a></div>
<div><span>🎙️ Audió: </span><a href="/toggle/audio" class="btn {{ 'btn-on' if config.audio_active else 'btn-off' }}">{{ 'AKTÍV' if config.audio_active else 'KI' }}</a></div>
<p style="color:#888; font-size:0.8em; margin-top:15px;">Cél: tcp://{{ config.pc_ip }}:{{ config.port }}</p>
</div></body></html>
"""

@app.route('/')
def index(): return render_template_string(HTML_UI, config=load_config())

@app.route('/save_ip', methods=['POST'])
def save_ip():
    config = load_config()
    config['pc_ip'] = request.form.get('pc_ip')
    save_config(config)
    return redirect('/')

@app.route('/toggle/<stream_type>')
def toggle_stream(stream_type):
    config = load_config()
    key = f"{stream_type}_active"
    if key in config: config[key] = not config[key]
    save_config(config)
    return redirect('/')

def check_usb_status():
    try:
        lsusb = subprocess.check_output("lsusb", shell=True).decode("utf-8")
        cam_ready = "045e:02ae" in lsusb
        audio_ready = "045e:02be" in lsusb or "045e:02bf" in lsusb
        return cam_ready, audio_ready
    except: return False, False

def streamer_loop():
    ctx = zmq.Context()
    p = pyaudio.PyAudio()
    audio_stream = None
    socket = None

    def get_socket():
        cfg = load_config()
        s = ctx.socket(zmq.PUB)
        s.setsockopt(zmq.SNDHWM, 1)
        s.connect(f"tcp://{cfg['pc_ip']}:{cfg['port']}")
        return s

    socket = get_socket()
    print("[SYSTEM] Node üzemkész. PC IP:", load_config()['pc_ip'])

    last_hw_check = 0
    cam_ok, audio_ok = False, False

    while True:
        now = time.time()
        cfg = load_config()

        if reconnect_event.is_set():
            socket.close(); socket = get_socket(); reconnect_event.clear()

        # Hardver ellenőrzés
        if now - last_hw_check > 3.0:
            old_audio = audio_ok
            cam_ok, audio_ok = check_usb_status()
            if audio_ok and not old_audio:
                print("[HARDVER] MIKROFON FIRMWARE OK! (Eszköz aktív)")
            elif not audio_ok and old_audio:
                print("[HARDVER] Mikrofon lecsatlakozott.")
            last_hw_check = now

        # Videó küldés
        if cfg['video_active'] and cam_ok:
            try:
                v_data, _ = freenect.sync_get_video()
                if v_data is not None:
                    _, img_enc = cv2.imencode('.jpg', v_data, [cv2.IMWRITE_JPEG_QUALITY, 60])
                    socket.send_multipart([b"video", img_enc.tobytes()])
            except: pass

        # MÉLYSÉG küldés (Külön kezelve!)
        if cfg['depth_active'] and cam_ok:
            try:
                d_data, _ = freenect.sync_get_depth()
                if d_data is not None:
                    socket.send_multipart([b"depth", d_data.tobytes()])
            except: pass

        # Audió küldés
        if cfg['audio_active'] and audio_ok:
            if audio_stream is None:
                try:
                    audio_stream = p.open(format=pyaudio.paInt16, channels=1, rate=16000, input=True, frames_per_buffer=1024)
                    print("[AUDIO] Stream megnyitva.")
                except: audio_stream = None
            if audio_stream:
                try:
                    a_data = audio_stream.read(1024, exception_on_overflow=False)
                    socket.send_multipart([b"audio", a_data])
                except:
                    audio_stream.close(); audio_stream = None
        else:
            if audio_stream: audio_stream.close(); audio_stream = None

        time.sleep(0.005)

if __name__ == "__main__":
    threading.Thread(target=lambda: app.run(host='0.0.0.0', port=5000), daemon=True).start()
    streamer_loop()
