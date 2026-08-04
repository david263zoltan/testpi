#!/bin/bash

# JARVIS NODE OS v7.0 - Raspberry Pi OS Lite Trixie 13 Installer
# Sudo kompatibilis

set -e

echo "=================================================="
echo "🚀 JARVIS NODE OS v7.0 - RASPBERRY PI INSTALLER"
echo "=================================================="
echo ""

# Ellenőrizzük a sudo-t (vagy root jogot)
if [ "$EUID" -ne 0 ]; then 
    echo "❌ Hiba: Ennek a scriptnek root jogokra van szüksége!"
    echo "Futtasd így: sudo bash install.sh"
    exit 1
fi

# Útvonalak automatikus meghatározása
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/pi_node"
PYTHON_VERSION="3.12.3"

# Felhasználó nélkül futó csomag
if [ -z "$SUDO_USER" ]; then
    REAL_USER="$USER"
else
    REAL_USER="$SUDO_USER"
fi

REAL_HOME=$(eval echo ~$REAL_USER)

echo "📍 Script könyvtár: $SCRIPT_DIR"
echo "📍 Projekt könyvtár: $PROJECT_DIR"
echo "📍 Python verzió: $PYTHON_VERSION"
echo "📍 Felhasználó: $REAL_USER"
echo ""

# Step 1: Rendszer frissítése
echo "[1/9] 🔄 Rendszer frissítése és alapcsomagok telepítése..."
apt-get update
apt-get install -y git cmake build-essential libusb-1.0-0-dev \
libfreenect-dev python3-dev cython3 libportaudio2 portaudio19-dev \
kinect-audio-setup cabextract wget curl llvm libssl-dev zlib1g-dev \
libbz2-dev libreadline-dev libsqlite3-dev libncurses-dev xz-utils \
tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev libasound2-dev

# Step 2: Pyenv telepítése (a $REAL_USER-hez)
echo ""
echo "[2/9] 🐍 Pyenv telepítése..."
PYENV_HOME="${REAL_HOME}/.pyenv"

if [ ! -d "$PYENV_HOME" ]; then
    sudo -u "$REAL_USER" bash -c 'curl https://pyenv.run | bash'
    echo "✅ Pyenv telepítve"
else
    echo "✅ Pyenv már telepítve van"
fi

# Step 3: Python telepítése
echo ""
echo "[3/9] 📦 Python $PYTHON_VERSION telepítése (ez eltarthat 10-15 percig)..."

# Pyenv beállítása az aktuális shellben
export PYENV_ROOT="$PYENV_HOME"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"

# Python telepítése sudo-val
sudo -u "$REAL_USER" bash -c "
export PYENV_ROOT='$PYENV_HOME'
export PATH='\$PYENV_ROOT/bin:\$PATH'
eval \"\$(pyenv init -)\"
pyenv install -s $PYTHON_VERSION
pyenv global $PYTHON_VERSION
"

echo "✅ Python telepítve"

# Step 4: USB és Kinect szabályok
echo ""
echo "[4/9] 🔌 USB és Kinect udev szabályok beállítása..."
cat > /etc/udev/rules.d/51-kinect.rules << 'UDEV'
# Kinect v1 USB rules for libfreenect
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ae", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ad", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02b0", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02be", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02bf", MODE="0666"
UDEV
udevadm control --reload-rules && udevadm trigger
echo "✅ Udev szabályok beállítva"

# Step 5: Kinect Firmware
echo ""
echo "[5/9] 🎮 Kinect Firmware letöltése..."
mkdir -p /lib/firmware/kinect
FW_URL="https://download.microsoft.com/download/F/9/9/F99791F2-D5BE-478A-B77A-830AD14950C3/KinectSDK-v1.0-beta2-x86.msi"

if ! wget -q --timeout=10 "$FW_URL" -O /tmp/KinectSDK.msi 2>/dev/null; then
    echo "⚠️  Figyelmeztetés: Kinect firmware letöltése sikertelen (nem kritikus)"
else
    cabextract /tmp/KinectSDK.msi -F "UACFirmware.*" -d /tmp/ 2>/dev/null || true
    if [ -f /tmp/UACFirmware.* ]; then
        mv /tmp/UACFirmware.* /lib/firmware/kinect/UACFirmware
        chmod 644 /lib/firmware/kinect/UACFirmware
        echo "✅ Kinect firmware telepítve"
    fi
    rm -f /tmp/KinectSDK.msi
fi

# Firmware feltöltő script
cat > "${SCRIPT_DIR}/upload_kinect_fw.sh" << 'FW'
#!/bin/bash
if command -v kinect_upload_fw &> /dev/null; then
    kinect_upload_fw /lib/firmware/kinect/UACFirmware 2>/dev/null || true
fi
FW
chmod +x "${SCRIPT_DIR}/upload_kinect_fw.sh"

# Step 6: Virtuális környezet
echo ""
echo "[6/9] 🔧 Python virtuális környezet létrehozása..."
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

# Virtuális env a valódi Python-nal
sudo -u "$REAL_USER" bash -c "
export PYENV_ROOT='$PYENV_HOME'
export PATH='\$PYENV_ROOT/shims:\$PYENV_ROOT/bin:\$PATH'
python -m venv env
"
echo "✅ Virtuális környezet létrehozva"

# Step 7: Python csomagok
echo ""
echo "[7/9] 📚 Python csomagok telepítése..."
cd "$PROJECT_DIR"

sudo -u "$REAL_USER" bash -c "
cd '$PROJECT_DIR'
source env/bin/activate
pip install --upgrade pip setuptools wheel
pip install 'cython==0.29.37' 'numpy==1.26.4'
pip install 'pyzmq' 'opencv-python-headless==4.9.0.80' 'pyaudio' 'flask' 'duckduckgo-search'
"
echo "✅ Python csomagok telepítve"

# Step 8: Libfreenect fordítása
echo ""
echo "[8/9] 🔨 Libfreenect Python driver fordítása..."
cd "$SCRIPT_DIR"

if [ ! -d "libfreenect" ]; then
    git clone https://github.com/OpenKinect/libfreenect.git
fi

cd libfreenect/wrappers/python
rm -rf build/ 2>/dev/null || true
rm -f freenect.c 2>/dev/null || true

sudo -u "$REAL_USER" bash -c "
cd '$SCRIPT_DIR/libfreenect/wrappers/python'
source '$PROJECT_DIR/env/bin/activate'
python setup.py install
"
echo "✅ Libfreenect fordítva és telepítve"

# Step 9: Autostart beállítása
echo ""
echo "[9/9] ⏰ Autostart beállítása (crontab)..."

# Crontab az eredeti felhasználónak
sudo -u "$REAL_USER" bash -c "
(crontab -l 2>/dev/null | grep -v 'sender.py'; echo '@reboot cd $PROJECT_DIR && $PROJECT_DIR/env/bin/python $PROJECT_DIR/sender.py >> $SCRIPT_DIR/jarvis_node.log 2>&1') | crontab -
"
echo "✅ Autostart beállítva"

# Végszó
echo ""
echo "=================================================="
echo "✅ TELEPÍTÉS KÉSZ!"
echo "=================================================="
echo ""
echo "📋 Következő lépések:"
echo "   1. A sender.py fájl létrehozása: $PROJECT_DIR/sender.py"
echo "   2. A daemons.py fájl létrehozása: $PROJECT_DIR/daemons.py (ha szükséges)"
echo "   3. Rendszer újraindítása: sudo reboot"
echo ""
echo "📁 Projekt könyvtára: $PROJECT_DIR"
echo "🔗 Python env: $PROJECT_DIR/env"
echo ""
echo "🧪 Tesztelés (mielőtt újraindítanál):"
echo "   cd $PROJECT_DIR"
echo "   source env/bin/activate"
echo "   python sender.py"
echo ""
