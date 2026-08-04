cat << 'EOF' > /root/testpi/Installer.sh
#!/bin/bash

# Hiba esetén álljon meg
set -e

echo "=================================================="
echo "🚀 JARVIS NODE OS v7.0 - SUDO COMPATIBLE"
echo "=================================================="

# Útvonalak automatikus meghatározása
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$SCRIPT_DIR/pi_node"
PYTHON_VERSION="3.12.3"

# Ellenőrizzük a sudo-t (vagy root jogot)
if [ "$EUID" -ne 0 ]; then 
  echo "Kérlek, futtasd sudo-val: sudo ./Installer.sh"
  exit 1
fi

echo "[1/8] Rendszer frissítése és alapcsomagok..."
apt-get update
apt-get install -y git cmake build-essential libusb-1.0-0-dev \
libfreenect-dev python3-dev cython3 libportaudio2 portaudio19-dev \
kinect-audio-setup cabextract wget curl llvm libssl-dev zlib1g-dev \
libbz2-dev libreadline-dev libsqlite3-dev libncurses-dev xz-utils \
tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev libasound2-dev

echo "[2/8] Pyenv telepítése..."
if [ ! -d "$HOME/.pyenv" ]; then
    curl https://pyenv.run | bash
fi

# Pyenv elérési utak beállítása a környezetbe
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"

echo "[3/8] Python $PYTHON_VERSION telepítése (ez hosszú lesz)..."
pyenv install -s "$PYTHON_VERSION"
pyenv global "$PYTHON_VERSION"

echo "[4/8] USB és Kinect szabályok beállítása..."
cat << 'UDEV' > /etc/udev/rules.d/51-kinect.rules
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ae", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ad", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02b0", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02be", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02bf", MODE="0666"
UDEV
udevadm control --reload-rules && udevadm trigger

echo "[5/8] Kinect Firmware letöltése és kicsomagolása..."
mkdir -p /lib/firmware/kinect
W_URL="https://download.microsoft.com/download/F/9/9/F99791F2-D5BE-478A-B77A-830AD14950C3/KinectSDK-v1.0-beta2-x86.msi"
wget -q $W_URL -O /tmp/KinectSDK.msi
cabextract /tmp/KinectSDK.msi -F "UACFirmware.*" -d /tmp/
mv /tmp/UACFirmware.* /lib/firmware/kinect/UACFirmware
rm /tmp/KinectSDK.msi

# Firmware feltöltő script
cat << 'FW' > "$SCRIPT_DIR/upload_kinect_fw.sh"
#!/bin/bash
kinect_upload_fw /lib/firmware/kinect/UACFirmware || true
FW
chmod +x "$SCRIPT_DIR/upload_kinect_fw.sh"

echo "[6/8] Virtuális környezet létrehozása..."
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"
python -m venv env
source env/bin/activate

echo "[7/8] Python könyvtárak (C-alapú fordítás)..."
pip install --upgrade pip
pip install "cython==0.29.37" "numpy==1.26.4"
pip install pyzmq "opencv-python-headless<4.10" pyaudio flask duckduckgo-search

echo "[8/8] Freenect Python driver fordítása..."
cd "$SCRIPT_DIR"
if [ ! -d "libfreenect" ]; then
    git clone https://github.com/OpenKinect/libfreenect.git
fi
cd libfreenect/wrappers/python
rm -rf build/
[ -f freenect.c ] && rm freenect.c
python setup.py install

echo "[AUTOSTART] Crontab beállítása..."
(crontab -l 2>/dev/null | grep -v "sender.py"; echo "@reboot cd $PROJECT_DIR && $PROJECT_DIR/env/bin/python $PROJECT_DIR/sender.py >> $SCRIPT_DIR/jarvis_node.log 2>&1") | crontab -

echo "=================================================="
echo "✅ TELEPÍTÉS KÉSZ! Indítás: sudo reboot"
echo "=================================================="
EOF#!/bin/bash
set -e

echo "=================================================="
echo "🚀 JARVIS NODE OS v6.9 - NO-SWAP & CLEAN"
echo "=================================================="

# Mappa struktúra rögzítése
SCRIPT_DIR="/root/testpi"
PROJECT_DIR="/root/testpi/pi_node"
PYTHON_VERSION="3.12.3"

echo "[1/9] Rendszerfrissítés és függőségek..."
apt-get update
apt-get install -y git cmake build-essential libusb-1.0-0-dev \
libfreenect-dev python3-dev cython3 libportaudio2 portaudio19-dev \
kinect-audio-setup cabextract wget curl llvm libssl-dev zlib1g-dev \
libbz2-dev libreadline-dev libsqlite3-dev libncurses-dev xz-utils \
tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev libasound2-dev

echo "[2/9] Pyenv telepítése..."
if [ ! -d "/root/.pyenv" ]; then
    curl https://pyenv.run | bash
fi

export PYENV_ROOT="/root/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"

echo "Python $PYTHON_VERSION telepítése (Ez eltarthat egy ideig)..."
pyenv install -s "$PYTHON_VERSION"
pyenv global "$PYTHON_VERSION"

echo "[3/9] USB szabályok beállítása..."
cat << 'EOF' > /etc/udev/rules.d/51-kinect.rules
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ae", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ad", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02b0", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02be", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02bf", MODE="0666"
EOF
udevadm control --reload-rules && udevadm trigger

echo "[4/9] Kinect Firmware letöltése..."
mkdir -p /lib/firmware/kinect
wget -q https://download.microsoft.com/download/F/9/9/F99791F2-D5BE-478A-B77A-830AD14950C3/KinectSDK-v1.0-beta2-x86.msi -O /tmp/KinectSDK.msi
cabextract /tmp/KinectSDK.msi -F "UACFirmware.*" -d /tmp/
mv /tmp/UACFirmware.* /lib/firmware/kinect/UACFirmware
rm /tmp/KinectSDK.msi

echo "[5/9] Firmware feltöltő script..."
cat << 'EOF' > /root/testpi/upload_kinect_fw.sh
#!/bin/bash
kinect_upload_fw /lib/firmware/kinect/UACFirmware || true
EOF
chmod +x /root/testpi/upload_kinect_fw.sh

cat << 'EOF' > /etc/udev/rules.d/55-kinect-audio-fw.rules
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ad", RUN+="/root/testpi/upload_kinect_fw.sh"
EOF

echo "[6/9] Virtuális környezet létrehozása..."
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"
python -m venv env
source env/bin/activate

echo "[7/9] Python modulok telepítése..."
pip install --upgrade pip
pip install "cython==0.29.37" "numpy==1.26.4"
pip install pyzmq "opencv-python-headless<4.10" pyaudio flask duckduckgo-search

echo "[8/9] Freenect driver fordítása..."
cd "$SCRIPT_DIR"
if [ ! -d "libfreenect" ]; then
    git clone https://github.com/OpenKinect/libfreenect.git
fi
cd libfreenect/wrappers/python
rm -rf build/
[ -f freenect.c ] && rm freenect.c
python setup.py install

echo "[9/9] Autostart beállítása..."
(crontab -l 2>/dev/null | grep -v "sender.py"; echo "@reboot cd $PROJECT_DIR && $PROJECT_DIR/env/bin/python $PROJECT_DIR/sender.py >> $SCRIPT_DIR/jarvis_node.log 2>&1") | crontab -

echo "=================================================="
echo "✅ TELEPÍTÉS KÉSZ! Reboot ajánlott."
echo "=================================================="#!/bin/bash
set -e

echo "=================================================="
echo "🚀 JARVIS NODE OS v6.8 - CLEAN & STABLE"
echo "=================================================="

# Mappa struktúra rögzítése
SCRIPT_DIR="/root/testpi"
PROJECT_DIR="$SCRIPT_DIR/pi_node"
PYTHON_VERSION="3.12.3"

echo "[1/10] Memória beállítása..."
if [ -f /etc/dphys-swapfile ]; then
    sed -i 's/CONF_SWAPSIZE=.*/CONF_SWAPSIZE=2048/' /etc/dphys-swapfile
    dphys-swapfile setup || true
    dphys-swapfile swapon || true
fi

echo "[2/10] Rendszerfrissítés és függőségek..."
apt-get update
apt-get install -y git cmake build-essential libusb-1.0-0-dev \
libfreenect-dev python3-dev cython3 libportaudio2 portaudio19-dev \
kinect-audio-setup cabextract wget curl llvm libssl-dev zlib1g-dev \
libbz2-dev libreadline-dev libsqlite3-dev libncurses-dev xz-utils \
tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev libasound2-dev

echo "[3/10] Pyenv telepítése..."
if [ ! -d "/root/.pyenv" ]; then
    curl https://pyenv.run | bash
fi

export PYENV_ROOT="/root/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"

echo "Python $PYTHON_VERSION telepítése (30-60 perc)..."
pyenv install -s "$PYTHON_VERSION"
pyenv global "$PYTHON_VERSION"

echo "[4/10] USB szabályok beállítása..."
cat << EOF > /etc/udev/rules.d/51-kinect.rules
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ae", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ad", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02b0", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02be", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02bf", MODE="0666"
EOF
udevadm control --reload-rules && udevadm trigger

echo "[5/10] Kinect Firmware..."
mkdir -p /lib/firmware/kinect
wget -q https://download.microsoft.com/download/F/9/9/F99791F2-D5BE-478A-B77A-830AD14950C3/KinectSDK-v1.0-beta2-x86.msi -O /tmp/KinectSDK.msi
cabextract /tmp/KinectSDK.msi -F "UACFirmware.*" -d /tmp/
mv /tmp/UACFirmware.* /lib/firmware/kinect/UACFirmware
rm /tmp/KinectSDK.msi

echo "[6/10] Firmware feltöltő..."
cat << EOF > $SCRIPT_DIR/upload_kinect_fw.sh
#!/bin/bash
kinect_upload_fw /lib/firmware/kinect/UACFirmware || true
EOF
chmod +x $SCRIPT_DIR/upload_kinect_fw.sh

echo "[7/10] Virtuális környezet..."
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"
python -m venv env
source env/bin/activate

echo "[8/10] Python modulok..."
pip install --upgrade pip
pip install "cython==0.29.37" "numpy==1.26.4"
pip install pyzmq "opencv-python-headless<4.10" pyaudio flask duckduckgo-search

echo "[9/10] Freenect fordítás..."
cd "$SCRIPT_DIR"
git clone https://github.com/OpenKinect/libfreenect.git || true
cd libfreenect/wrappers/python
rm -rf build/
[ -f freenect.c ] && rm freenect.c
python setup.py install

echo "[10/10] Autostart..."
(crontab -l 2>/dev/null | grep -v "sender.py"; echo "@reboot cd $PROJECT_DIR && $PROJECT_DIR/env/bin/python $PROJECT_DIR/sender.py >> $SCRIPT_DIR/jarvis_node.log 2>&1") | crontab -

echo "=================================================="
echo "✅ KÉSZ! INDÍTSD ÚJRA: reboot"
echo "=================================================="
