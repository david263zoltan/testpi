#!/bin/bash
set -e

echo "=================================================="
echo "🚀 JARVIS DIETPI ALL-IN-ONE INSTALLER v9.2"
echo "=================================================="

# 1. RENDSZER-KONFIGURÁCIÓ (USB Áramkorlát feloldása)
echo "[1/11] USB áramkorlát feloldása (max_usb_current=1)..."
CONFIG_PATH="/boot/config.txt"
[ ! -f "$CONFIG_PATH" ] && CONFIG_PATH="/boot/firmware/config.txt"

if grep -q "max_usb_current" "$CONFIG_PATH"; then
    sed -i 's/max_usb_current=.*/max_usb_current=1/' "$CONFIG_PATH"
else
    echo "max_usb_current=1" >> "$CONFIG_PATH"
fi

# 2. ALAPVETŐ CSOMAGOK (DietPi specifikus javításokkal)
echo "[2/11] Rendszerfüggőségek telepítése (Python 3.13 + Venv javítás)..."
apt-get update
apt-get install -y usbutils sudo git cmake build-essential libusb-1.0-0-dev \
libfreenect-dev python3-dev python3-venv cython3 libportaudio2 portaudio19-dev \
wget curl p7zip-full libasound2-dev libjpeg-dev

# 3. KINECT FIRMWARE KINYERÉSE
echo "[3/11] Kinect Firmware letöltése és kicsomagolása..."
mkdir -p /lib/firmware/kinect
cd /tmp
rm -f KinectSDK.msi UACFirmware*
wget -q "https://download.microsoft.com/download/F/9/9/F99791F2-D5BE-478A-B77A-830AD14950C3/KinectSDK-v1.0-beta2-x86.msi" -O KinectSDK.msi
7z e KinectSDK.msi "UACFirmware.*" -r -y > /dev/null
mv UACFirmware.* /lib/firmware/kinect/UACFirmware
chmod 644 /lib/firmware/kinect/UACFirmware

# 4. KINECT C-FELTÖLTŐ FORDÍTÁSA
echo "[4/11] C-alapú Firmware feltöltő fordítása..."
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

# 5. KÜLSŐ .SH FELTÖLTŐ ÉS UDEV SZABÁLYOK
echo "[5/11] Firmware feltöltő szkript és Udev automatizálás..."
cat << 'FW_SH' > /usr/local/bin/kinect_full_init.sh
#!/bin/bash
# Ezt a szkriptet hívja az Udev, ha meglátja a Kinectet
/usr/local/bin/kinect_upload_fw /lib/firmware/kinect/UACFirmware || true
FW_SH
chmod +x /usr/local/bin/kinect_full_init.sh

cat << 'EOF_RULES' > /etc/udev/rules.d/55-kinect-audio-fw.rules
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ad", RUN+="/usr/local/bin/kinect_full_init.sh"
EOF_RULES
udevadm control --reload-rules && udevadm trigger

# 6. PYTHON VIRTUÁLIS KÖRNYEZET
echo "[6/11] Python virtuális környezet létrehozása (env)..."
PROJECT_DIR="/root/testpi/pi_node"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"
rm -rf env
python3 -m venv env
source env/bin/activate

echo "[7/11] Python csomagok telepítése (Cython, Numpy, PyZMQ, OpenCV, Flask)..."
pip install --upgrade pip setuptools wheel
pip install "cython==0.29.37" "numpy==1.26.4" pyzmq "opencv-python-headless<4.10" pyaudio flask

# 7. LIBFREENECT WRAPPER FORDÍTÁSA
echo "[8/11] Libfreenect Python wrapper fordítása..."
cd /root/testpi
[ -d "libfreenect" ] && rm -rf libfreenect
git clone https://github.com/OpenKinect/libfreenect.git
cd libfreenect/wrappers/python
python setup.py install

# 8. SENDER.PY GENERÁLÁSA (Web UI + IP Config + Reboot)
echo "[9/11] Intelligens sender.py generálása..."
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
                cfg.setdefault("depth_active", True)
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
<head><title>Jarvis Node Control</title>
<style>
    body{background:#121212;color:white;text-align:center;font-family:sans-serif;padding:20px;}
    .card{background:#1e1e1e;padding:25px;border-radius:15px;display:inline-block;border:1px solid #00adb5;min-width:320px;}
    input{padding:10px;background:#000;border:1px solid #00adb5;color:white;border-radius:5px;width:180px;text-align:center;font-size:1.1em;}
    .btn{padding:12px 20px;border-radius:5px;border:none;font-weight:bold;cursor:pointer;text-decoration:none;color:black;margin:5px;display:inline-block;width:120px;}
    .btn-on{background:#28a745;color:white;}.btn-off{background:#dc3545;color:white;}
    .btn-reboot{background:#ff9800;color:black;width:280px;margin-top:20px; font-size:1em;}
    .save-btn{background:#00adb5; border:none; padding:10px; border-radius:5px; cursor:pointer; font-weight:bold; color:black;}
</style></head>
<body><div class="card">
    <h1>🛰️ Jarvis Node v9.2</h1>
    <form action="/save_ip" method="post">
        <input type="text" name="pc_ip" value="{{ config.pc_ip }}">
        <button type="submit" class="save-btn">IP MENTÉS</button>
    </form>
    <hr style="border:0.5px solid #333; margin:20px 0;">
    <div><span>📹 Videó: </span><a href="/toggle/video" class="btn {{ 'btn-on' if config.video_active else 'btn-off' }}">{{ 'ON' if config.video_active else 'OFF' }}</a></div>
    <div><span>📏 Mélység: </span><a href="/toggle/depth" class="btn {{ 'btn-on' if config.depth_active else 'btn-off' }}">{{ 'ON' if config.depth_active else 'OFF' }}</a></div>
    <div><span>🎙️ Audió: </span><a href="/toggle/audio" class="btn {{ 'btn-on' if config.audio_active else 'btn-off' }}">{{ 'ON' if config.audio_active else 'OFF' }}</a></div>
    
    <a href="/reboot" class="btn btn-reboot" onclick="return confirm('Biztosan újraindítod a Raspberry-t?')">🔄 RASPBERRY ÚJRAINDÍTÁSA</a>
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

@app.route('/reboot')
def reboot_node():
    threading.Thread(target=lambda: (time.sleep(2), os.system('reboot'))).start()
    return "<h1>Újraindítás... Várj 1 percet, majd frissíts!</h1>"

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
    audio_stream, socket = None, None

    def get_socket():
        cfg = load_config()
        s = ctx.socket(zmq.PUB)
        s.setsockopt(zmq.SNDHWM, 1)
        s.connect(f"tcp://{cfg['pc_ip']}:{cfg['port']}")
        return s

    socket = get_socket()
    last_hw_check = 0
    cam_ok, audio_ok = False, False

    while True:
        cfg = load_config()
        if reconnect_event.is_set():
            socket.close(); socket = get_socket(); reconnect_event.clear()

        if time.time() - last_hw_check > 3.0:
            cam_ok, audio_ok = check_usb_status()
            last_hw_check = time.time()

        if cfg['video_active'] and cam_ok:
            try:
                v_data, _ = freenect.sync_get_video()
                if v_data is not None:
                    _, img_enc = cv2.imencode('.jpg', v_data, [cv2.IMWRITE_JPEG_QUALITY, 60])
                    socket.send_multipart([b"video", img_enc.tobytes()])
            except: pass

        if cfg['depth_active'] and cam_ok:
            try:
                d_data, _ = freenect.sync_get_depth()
                if d_data is not None:
                    socket.send_multipart([b"depth", d_data.tobytes()])
            except: pass

        if cfg['audio_active'] and audio_ok:
            if audio_stream is None:
                try: audio_stream = p.open(format=pyaudio.paInt16, channels=1, rate=16000, input=True, frames_per_buffer=1024)
                except: audio_stream = None
            if audio_stream:
                try:
                    a_data = audio_stream.read(1024, exception_on_overflow=False)
                    socket.send_multipart([b"audio", a_data])
                except: audio_stream.close(); audio_stream = None
        else:
            if audio_stream: audio_stream.close(); audio_stream = None

        time.sleep(0.005)

if __name__ == "__main__":
    threading.Thread(target=lambda: app.run(host='0.0.0.0', port=5000), daemon=True).start()
    streamer_loop()
SENDER_PY

# 9. SYSTEMD SZOLGÁLTATÁS BEÁLLÍTÁSA
echo "[10/11] Systemd szolgáltatás (jarvis_node) konfigurálása..."
cat << SYSTEMD > /etc/systemd/system/jarvis_node.service
[Unit]
Description=Jarvis Kinect Node Service
After=network.target

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

echo "=================================================="
echo "✅ TELEPÍTÉS SIKERES!"
echo "A max_usb_current=1 aktiválásához ÚJRAINDÍTÁS SZÜKSÉGES."
echo "Futtasd most: sudo reboot"
echo "=================================================="
