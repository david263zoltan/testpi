#!/bin/bash
# JARVIS NODE OS v7.3 - KINECT-AUDIO-SETUP REMOVED & REPLACED
set -e

echo "=================================================="
echo "🚀 JARVIS NODE OS v7.3 - RASPBERRY PI INSTALLER"
echo "=================================================="

if [ "$EUID" -ne 0 ]; then 
    echo "❌ Hiba: Root jogokra van szükség!"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/pi_node"
PYTHON_VERSION="3.12.3"
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo ~$REAL_USER)
PYENV_ROOT="${REAL_HOME}/.pyenv"

echo "[1/9] 🔄 Alapcsomagok telepítése (ROSSZ CSOMAG KIVÉVE)..."
apt-get update
# Hozzáadtuk a libusb-1.0-0-dev-et a manuális uploader fordításához
apt-get install -y git cmake build-essential libusb-1.0-0-dev \
libfreenect-dev python3-dev cython3 libportaudio2 portaudio19-dev \
cabextract wget curl llvm libssl-dev zlib1g-dev \
libbz2-dev libreadline-dev libsqlite3-dev libncurses-dev xz-utils \
tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev libasound2-dev

echo "[2/9] 🐍 Pyenv telepítése..."
if [ ! -d "$PYENV_ROOT" ]; then
    sudo -u "$REAL_USER" bash -c 'curl https://pyenv.run | bash'
fi

# Pyenv elérési utak rögzítése
if ! grep -q "PYENV_ROOT" "${REAL_HOME}/.bashrc"; then
    echo "export PYENV_ROOT=\"$PYENV_ROOT\"" >> "${REAL_HOME}/.bashrc"
    echo "export PATH=\"\$PYENV_ROOT/bin:\$PATH\"" >> "${REAL_HOME}/.bashrc"
    echo "eval \"\$(pyenv init -)\"" >> "${REAL_HOME}/.bashrc"
fi

echo "[3/9] 📦 Python $PYTHON_VERSION fordítása..."
cat > /tmp/jarvis_pyenv_install.sh << EOF
#!/bin/bash
set -e
export PYENV_ROOT="$PYENV_ROOT"
export PATH="\$PYENV_ROOT/bin:\$PATH"
eval "\$(pyenv init -)"
pyenv install -s $PYTHON_VERSION
pyenv global $PYTHON_VERSION
EOF
chmod +x /tmp/jarvis_pyenv_install.sh
chown "$REAL_USER" /tmp/jarvis_pyenv_install.sh
sudo -u "$REAL_USER" bash /tmp/jarvis_pyenv_install.sh

echo "[4/9] 🔌 Kinect udev szabályok..."
cat > /etc/udev/rules.d/51-kinect.rules << 'UDEV'
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ae", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ad", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02b0", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02be", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02bf", MODE="0666"
UDEV
udevadm control --reload-rules && udevadm trigger

echo "[5/9] 🎮 Kinect Firmware és Feltöltő készítése..."
# 1. Letöltjük a feltöltő forráskódját és lefordítjuk helyben
cd /tmp
rm -rf kinect_setup || true
git clone https://github.com/avinlobo/kinect_setup.git
cd kinect_setup
gcc kinect_upload_fw.c -o kinect_upload_fw -lusb-1.0
cp kinect_upload_fw /usr/local/bin/

# 2. Firmware kinyerése az MSI-ből
mkdir -p /lib/firmware/kinect
FW_URL="https://download.microsoft.com/download/F/9/9/F99791F2-D5BE-478A-B77A-830AD14950C3/KinectSDK-v1.0-beta2-x86.msi"
wget -q "$FW_URL" -O /tmp/KinectSDK.msi
cabextract /tmp/KinectSDK.msi -F "UACFirmware.*" -d /tmp/
mv /tmp/UACFirmware.* /lib/firmware/kinect/UACFirmware

# 3. Egyedi feltöltő script létrehozása
cat > "${SCRIPT_DIR}/upload_kinect_fw.sh" << 'FW'
#!/bin/bash
/usr/local/bin/kinect_upload_fw /lib/firmware/kinect/UACFirmware || true
FW
chmod +x "${SCRIPT_DIR}/upload_kinect_fw.sh"

echo "[6/9] 🔧 Virtuális környezet..."
mkdir -p "$PROJECT_DIR"
sudo -u "$REAL_USER" bash -c "$PYENV_ROOT/versions/$PYTHON_VERSION/bin/python -m venv '$PROJECT_DIR/env'"

echo "[7/9] 📚 Python csomagok..."
sudo -u "$REAL_USER" bash -c "
    source '$PROJECT_DIR/env/bin/activate'
    pip install --upgrade pip setuptools wheel
    pip install 'cython==0.29.37' 'numpy==1.26.4'
    pip install pyzmq 'opencv-python-headless==4.9.0.80' pyaudio flask duckduckgo-search
"

echo "[8/9] 🔨 Libfreenect driver..."
cd "$SCRIPT_DIR"
[ ! -d "libfreenect" ] && git clone https://github.com/OpenKinect/libfreenect.git
cd libfreenect/wrappers/python
rm -rf build/ freenect.c || true
sudo -u "$REAL_USER" bash -c "source '$PROJECT_DIR/env/bin/activate'; python setup.py install"

echo "[9/9] ⏰ Autostart beállítása..."
sudo -u "$REAL_USER" bash -c "(crontab -l 2>/dev/null | grep -v 'sender.py'; echo '@reboot cd $PROJECT_DIR && $PROJECT_DIR/env/bin/python $PROJECT_DIR/sender.py >> $SCRIPT_DIR/jarvis_node.log 2>&1') | crontab -"

echo "✅ TELEPÍTÉS KÉSZ! Reboot ajánlott: sudo reboot"
