cat << 'EOF' > /root/testpi/finish_install.sh
#!/bin/bash
set -e

echo "=================================================="
echo "🚀 JARVIS NODE OS - TELEPÍTÉS BEFEJEZÉSE (7-ZIP)"
echo "=================================================="

SCRIPT_DIR="/root/testpi"
PROJECT_DIR="$SCRIPT_DIR/pi_node"
PYTHON_VERSION="3.12.3"

# Betöltjük a Pyenv-et
export PYENV_ROOT="/root/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
pyenv global $PYTHON_VERSION

echo "[5/9] 🎮 Kinect Firmware kinyerése 7-Zip segítségével..."
apt-get install -y p7zip-full
mkdir -p /lib/firmware/kinect
cd /tmp
rm -f KinectSDK.msi UACFirmware*

FW_URL="https://download.microsoft.com/download/F/9/9/F99791F2-D5BE-478A-B77A-830AD14950C3/KinectSDK-v1.0-beta2-x86.msi"
wget -c "$FW_URL" -O KinectSDK.msi

# ITT A VARÁZSLAT, amire emlékeztél:
7z e KinectSDK.msi "UACFirmware.*" -r

mv UACFirmware.* /lib/firmware/kinect/UACFirmware
chmod 644 /lib/firmware/kinect/UACFirmware
rm -f KinectSDK.msi
echo "✅ Firmware sikeresen kicsomagolva és a helyére másolva!"

echo "[6/9] 🔧 Virtuális környezet beállítása..."
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"
if [ ! -d "env" ]; then
    python -m venv env
fi
source env/bin/activate

echo "[7/9] 📚 Python csomagok telepítése..."
pip install --upgrade pip setuptools wheel
pip install "cython==0.29.37" "numpy==1.26.4"
pip install pyzmq "opencv-python-headless<4.10" pyaudio flask duckduckgo-search

echo "[8/9] 🔨 Libfreenect driver fordítása..."
cd "$SCRIPT_DIR"
[ ! -d "libfreenect" ] && git clone https://github.com/OpenKinect/libfreenect.git
cd libfreenect/wrappers/python
rm -rf build/ freenect.c || true
python setup.py install

echo "[9/9] ⏰ Autostart beállítása..."
(crontab -l 2>/dev/null | grep -v "sender.py"; echo "@reboot cd $PROJECT_DIR && $PROJECT_DIR/env/bin/python $PROJECT_DIR/sender.py >> $SCRIPT_DIR/jarvis_node.log 2>&1") | crontab -

echo "=================================================="
echo "✅ KÉSZ! MINDEN TELEPÍTVE."
echo "Indítsd újra a gépet a következő paranccsal: reboot"
echo "=================================================="
EOF
