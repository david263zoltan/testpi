#!/bin/bash
set -e

echo "=================================================="
echo "🚀 JARVIS NODE OS v6.7 - DEBIAN TRIXIE FIX"
echo "=================================================="

# Útvonalak
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$SCRIPT_DIR/pi_node"
PYTHON_VERSION="3.12.3"

echo "[1/10] Memória bővítése..."
# Ha nincs elindítva, elindítjuk
systemctl start dphys-swapfile || true
sed -i 's/CONF_SWAPSIZE=.*/CONF_SWAPSIZE=2048/' /etc/dphys-swapfile
dphys-swapfile setup
dphys-swapfile swapon

echo "[2/10] Rendszerfüggőségek telepítése..."
apt update
apt install -y git cmake build-essential libusb-1.0-0-dev \
libfreenect-dev python3-dev cython3 libportaudio2 portaudio19-dev \
kinect-audio-setup cabextract wget curl llvm libssl-dev zlib1g-dev \
libbz2-dev libreadline-dev libsqlite3-dev libncurses-dev xz-utils \
tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev libasound2-dev

echo "[3/10] Pyenv és Python $PYTHON_VERSION telepítése..."
if [ ! -d "$HOME/.pyenv" ]; then
    curl https://pyenv.run | bash
fi

export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"

# Python fordítás
pyenv install -s "$PYTHON_VERSION"
pyenv global "$PYTHON_VERSION"

echo "[4/10] USB Jogosultságok beállítása..."
cat << EOF > /etc/udev/rules.d/51-kinect.rules
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ae", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ad", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02b0", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02be", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02bf", MODE="0666"
EOF
udevadm control --reload-rules && udevadm trigger

echo "[5/10] Kinect Firmware kinyerése..."
mkdir -p /lib/firmware/kinect
wget -q https://download.microsoft.com/download/F/9/9/F99791F2-D5BE-478A-B77A-830AD14950C3/KinectSDK-v1.0-beta2-x86.msi -O /tmp/KinectSDK.msi
cabextract /tmp/KinectSDK.msi -F "UACFirmware.*" -d /tmp/
mv /tmp/UACFirmware.* /lib/firmware/kinect/UACFirmware
rm /tmp/KinectSDK.msi

echo "[6/10] Automatikus Firmware feltöltő beállítása..."
cat << EOF > "$SCRIPT_DIR/upload_kinect_fw.sh"
#!/bin/bash
kinect_upload_fw /lib/firmware/kinect/UACFirmware || true
EOF
chmod +x "$SCRIPT_DIR/upload_kinect_fw.sh"

cat << EOF > /etc/udev/rules.d/55-kinect-audio-fw.rules
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}==\"02ad\", RUN+=\"$SCRIPT_DIR/upload_kinect_fw.sh\"
EOF

echo "[7/10] Virtuális környezet létrehozása..."
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"
python -m venv env
source env/bin/activate

echo "[8/10] Python könyvtárak telepítése..."
pip install --upgrade pip
pip install "cython==0.29.37" "numpy==1.26.4"
pip install pyzmq "opencv-python-headless<4.10" pyaudio flask

echo "[9/10] Freenect driver fordítása..."
cd "$SCRIPT_DIR"
git clone https://github.com/OpenKinect/libfreenect.git || true
cd libfreenect/wrappers/python
rm -rf build/
[ -f freenect.c ] && rm freenect.c
python setup.py install

echo "[10/10] Automatikus indítás beállítása..."
(crontab -l 2>/dev/null | grep -v "sender.py"; echo "@reboot cd $PROJECT_DIR && $PROJECT_DIR/env/bin/python $PROJECT_DIR/sender.py >> $SCRIPT_DIR/jarvis_node.log 2>&1") | crontab -

echo "=================================================="
echo "✅ TELEPÍTÉS KÉSZ! INDÍTSD ÚJRA A RASPBERRY-T!"
echo "=================================================="
