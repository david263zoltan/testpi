#!/bin/bash
set -e

echo "=================================================="
echo "🚀 JARVIS NODE OS v8.1 - ALL-IN-ONE (install.sh)"
echo "=================================================="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/pi_node"
PYTHON_VERSION="3.12.3"

export PYENV_ROOT="/root/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"

echo "[1/10] Rendszerfüggőségek és 7-Zip telepítése..."
apt-get update
apt-get install -y git cmake build-essential libusb-1.0-0-dev \
libfreenect-dev python3-dev cython3 libportaudio2 portaudio19-dev \
wget curl llvm libssl-dev zlib1g-dev p7zip-full \
libbz2-dev libreadline-dev libsqlite3-dev libncurses-dev xz-utils \
tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev libasound2-dev

echo "[2/10] Pyenv és Python $PYTHON_VERSION beállítása..."
if [ ! -d "$PYENV_ROOT" ]; then
    curl https://pyenv.run | bash
fi
eval "$(pyenv init -)"
pyenv install -s "$PYTHON_VERSION"
pyenv global "$PYTHON_VERSION"

echo "[3/10] Kinect udev szabályok..."
cat << 'UDEV' > /etc/udev/rules.d/51-kinect.rules
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ae", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ad", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02b0", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02be", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02bf", MODE="0666"
UDEV
udevadm control --reload-rules && udevadm trigger

echo "[4/10] Kinect Firmware feltöltő C-kód fordítása..."
cd /tmp
cat << 'C_CODE' > kinect_upload_fw.c
#include <stdio.h>
#include <stdlib.h>
#include <libusb-1.0/libusb.h>
int main(int argc, char *argv[]) {
    if (argc < 2) return 1;
    libusb_context *ctx = NULL;
    libusb_device_handle *dev_handle = NULL;
    if (libusb_init(&ctx) < 0) return 1;
    dev_handle = libusb_open_device_with_vid_pid(ctx, 0x045e, 0x02ad);
    if (!dev_handle) return 1;
    FILE *fw = fopen(argv[1], "rb");
    if (!fw) return 1;
    fseek(fw, 0, SEEK_END);
    long fw_size = ftell(fw);
    fseek(fw, 0, SEEK_SET);
    unsigned char *buffer = malloc(fw_size);
    fread(buffer, 1, fw_size, fw);
    fclose(fw);
    int transferred;
    libusb_bulk_transfer(dev_handle, 1, buffer, fw_size, &transferred, 10000);
    free(buffer);
    libusb_close(dev_handle);
    libusb_exit(ctx);
    return 0;
}
C_CODE
gcc kinect_upload_fw.c -o kinect_upload_fw -lusb-1.0
cp kinect_upload_fw /usr/local/bin/
chmod +x /usr/local/bin/kinect_upload_fw

echo "[5/10] Kinect Firmware kinyerése (7-Zip módszer)..."
mkdir -p /lib/firmware/kinect
cd /tmp
rm -f KinectSDK.msi UACFirmware*
wget -q "https://download.microsoft.com/download/F/9/9/F99791F2-D5BE-478A-B77A-830AD14950C3/KinectSDK-v1.0-beta2-x86.msi" -O KinectSDK.msi
7z e KinectSDK.msi "UACFirmware.*" -r -y > /dev/null
mv UACFirmware.* /lib/firmware/kinect/UACFirmware
chmod 644 /lib/firmware/kinect/UACFirmware
rm -f KinectSDK.msi

cat << 'FW' > "$SCRIPT_DIR/upload_kinect_fw.sh"
#!/bin/bash
/usr/local/bin/kinect_upload_fw /lib/firmware/kinect/UACFirmware || true
FW
chmod +x "$SCRIPT_DIR/upload_kinect_fw.sh"

cat << 'EOF_RULES' > /etc/udev/rules.d/55-kinect-audio-fw.rules
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ad", RUN+="/usr/local/bin/kinect_upload_fw /lib/firmware/kinect/UACFirmware"
EOF_RULES
udevadm control --reload-rules && udevadm trigger

echo "[6/10] Python virtuális környezet és csomagok..."
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"
if [ ! -d "env" ]; then
    python -m venv env
fi
source env/bin/activate
pip install --upgrade pip setuptools wheel
pip install "cython==0.29.37" "numpy==1.26.4"
pip install pyzmq "opencv-python-headless<4.10" pyaudio flask

echo "[7/10] Libfreenect driver fordítása..."
cd "$SCRIPT_DIR"
[ ! -d "libfreenect" ] && git clone https://github.com/OpenKinect/libfreenect.git
cd libfreenect/wrappers/python
rm -rf build/ freenect.c || true
python setup.py install

echo "[8/10] SENDER.PY fájl generálása..."
cat << 'SENDER_PY' > "$PROJECT_DIR/sender.py"
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
                cfg.setdefault("audio_active", True)
                return cfg
        except: pass
    return {"pc_ip": "192.168.1.140", "port": 5555, "video_active": True, "audio_active": True}

def save_config(data):
    with open(CONFIG_FILE, "w") as f: json.dump(data, f, indent=4)
    reconnect_event.set()

app = Flask(__name__)

HTML_UI = """
<!DOCTYPE html>
<html>
<head><title>Jarvis Node</title>
<style>body{background:#121212;color:white;text-align:center;padding:50px;font-family:sans-serif;}
.card{background:#1e1e1e;padding:30px;border-radius:15px;display:inline-block;border:1px solid #00adb5;}
input{padding:10px;border-radius:5px;border:1px solid #333;background:#000;color:white;}
.btn{padding:10px 20px;border-radius:5px;border:none;font-weight:bold;cursor:pointer;text-decoration:none;color:black;margin:10px;}
.btn-save{background:#00adb5;}.btn-on{background:#28a745;color:white;}.btn-off{background:#dc3545;color:white;}</style>
</head><body>
<div class="card"><h1>🛰️ Jarvis Node v6.5</h1>
<form action="/save_ip" method="post">
<input type="text" name="pc_ip" value="{{ config.pc_ip }}"><button type="submit" class="btn btn-save">IP Mentése</button>
</form><br>
<div><span>📹 Videó: </span><a href="/toggle/video" class="btn {{ 'btn-on' if config.video_active else 'btn-off' }}">{{ 'AKTÍV' if config.video_active else 'KI' }}</a></div>
<div><span>🎙️ Audió: </span><a href="/toggle/audio" class="btn {{ 'btn-on' if config.audio_active else 'btn-off' }}">{{ 'AKTÍV' if config.audio_active else 'KI' }}</a></div>
<p style="color:#888;">Cél: tcp://{{ config.pc_ip }}:{{ config.port }}</p></div></body></html>
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
    if stream_type == "video": config['video_active'] = not config['video_active']
    elif stream_type == "audio": config['audio_active'] = not config['audio_active']
    save_config(config)
    return redirect('/')

def run_web_server():
    app.run(host='0.0.0.0', port=5000, debug=False, use_reloader=False)

def streamer_loop():
    try: subprocess.run(["sudo", "/usr/local/bin/kinect_upload_fw", "/lib/firmware/kinect/UACFirmware"], check=False)
    except: pass
    ctx = zmq.Context()
    p = pyaudio.PyAudio()
    audio_stream = p.open(format=pyaudio.paInt16, channels=1, rate=16000, input=True, frames_per_buffer=1024)
    
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
            socket.close(); socket = create_socket(); reconnect_event.clear()
        try:
            if cfg['video_active']:
                v_data = freenect.sync_get_video()
                d_data = freenect.sync_get_depth()
                if v_data and d_data:
                    _, img_enc = cv2.imencode('.jpg', v_data[0], [cv2.IMWRITE_JPEG_QUALITY, 70])
                    socket.send_multipart([b"video", img_enc.tobytes()])
                    socket.send_multipart([b"depth", d_data[0].tobytes()])
            if cfg['audio_active']:
                audio_data = audio_stream.read(1024, exception_on_overflow=False)
                socket.send_multipart([b"audio", audio_data])
            if not cfg['video_active'] and not cfg['audio_active']: time.sleep(0.5)
        except Exception as e:
            print(f"[ERROR] Stream hiba: {e}"); time.sleep(1)
        time.sleep(0.01)

if __name__ == "__main__":
    threading.Thread(target=run_web_server, daemon=True).start()
    streamer_loop()
SENDER_PY

echo "[9/10] Rendszerszolgáltatás (Systemd) beállítása..."
cat << SYSTEMD > /etc/systemd/system/jarvis_node.service
[Unit]
Description=Jarvis Kinect Node Service
After=network.target network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$PROJECT_DIR
ExecStart=$PROJECT_DIR/env/bin/python $PROJECT_DIR/sender.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload
systemctl enable jarvis_node.service
systemctl start jarvis_node.service

crontab -r 2>/dev/null || true

echo "=================================================="
echo "✅ MINDEN KÉSZ ÉS A SZERVER MÁR FUT!"
echo "Ellenőrizd a böngésződben: http://<RASPBERRY_IP>:5000"
echo "=================================================="
