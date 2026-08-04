#!/bin/bash

# Hiba esetén álljon meg
set -e

echo "=================================================="
echo "🚀 JARVIS NODE OS v6.6 - MAPPASZERKEZETRE SZABVA"
echo "=================================================="

# --- ÚTVONALAK MEGHATÁROZÁSA ---
# Megkeressük, hol fut a script (ez lesz a 'Raspberry kinect' mappa)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$SCRIPT_DIR/pi_node"
USER_HOME=$(eval echo ~$USER)

echo "[INFO] Telepítési mappa: $PROJECT_DIR"

echo "[1/10] SWAP Memória növelése (2GB)..."
sudo dphys-swapfile swapoff || true
sudo sed -i 's/CONF_SWAPSIZE=.*/CONF_SWAPSIZE=2048/' /etc/dphys-swapfile
sudo dphys-swapfile setup
sudo dphys-swapfile swapon

echo "[2/10] Rendszerfüggőségek telepítése..."
sudo apt update
sudo apt install -y git cmake build-essential libusb-1.0-0-dev \
libfreenect-dev python3-dev cython3 libportaudio2 portaudio19-dev \
kinect-audio-setup cabextract wget curl llvm libssl-dev zlib1g-dev \
libbz2-dev libreadline-dev libsqlite3-dev libncurses-dev xz-utils \
tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev libasound2-dev

echo "[3/10] Pyenv és Python 3.12.3 telepítése..."
if [ -d "$HOME/.pyenv" ]; then
    echo "Pyenv már telepítve."
else
    curl https://pyenv.run | bash
fi

export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"

pyenv install -s "3.12.3"
pyenv global "3.12.3"

echo "[4/10] USB Jogosultságok (udev) beállítása..."
sudo bash -c 'cat << EOF > /etc/udev/rules.d/51-kinect.rules
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ae", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ad", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02b0", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02be", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02bf", MODE="0666"
EOF'

echo "[5/10] Kinect Audió Firmware kinyerése..."
sudo mkdir -p /lib/firmware/kinect
WAV_URL="https://download.microsoft.com/download/F/9/9/F99791F2-D5BE-478A-B77A-830AD14950C3/KinectSDK-v1.0-beta2-x86.msi"
wget -q $WAV_URL -O /tmp/KinectSDK.msi
cabextract /tmp/KinectSDK.msi -F "UACFirmware.*" -d /tmp/
sudo mv /tmp/UACFirmware.* /lib/firmware/kinect/UACFirmware
rm /tmp/KinectSDK.msi

echo "[6/10] Firmware feltöltő script létrehozása..."
cat << 'EOF' > "$SCRIPT_DIR/upload_kinect_fw.sh"
#!/bin/bash
FIRMWARE_PATH="/lib/firmware/kinect/UACFirmware"
sudo kinect_upload_fw "$FIRMWARE_PATH" || echo "Firmware hiba."
EOF
chmod +x "$SCRIPT_DIR/upload_kinect_fw.sh"

echo "[7/10] Virtuális környezet (venv) létrehozása a pi_node-ban..."
cd "$PROJECT_DIR"
python -m venv env
source env/bin/activate

echo "[8/10] Python modulok telepítése..."
pip install --upgrade pip
pip install "cython==0.29.37" "numpy==1.26.4"
pip install pyzmq "opencv-python-headless<4.10" pyaudio flask

echo "[9/10] Freenect driver fordítása..."
cd "$SCRIPT_DIR"
if [ -d "libfreenect" ]; then rm -rf libfreenect; fi
git clone https://github.com/OpenKinect/libfreenect.git
cd libfreenect/wrappers/python
rm -rf build/
[ -f freenect.c ] && rm freenect.c
python setup.py install

echo "[10/10] Automatikus indítás (Cron job) beállítása..."
# Itt adjuk meg a pontos útvonalat a te pi_node/sender.py fájlodhoz
(crontab -l 2>/dev/null | grep -v "sender.py"; echo "@reboot cd $PROJECT_DIR && $PROJECT_DIR/env/bin/python $PROJECT_DIR/sender.py >> $SCRIPT_DIR/jarvis_node.log 2>&1") | crontab -

echo "=================================================="
echo "✅ TELEPÍTÉS KÉSZ!"
echo "Minden beállítva a te mappaszerkezetedhez!"
echo "Fő mappa: $SCRIPT_DIR"
echo "Projekt: $PROJECT_DIR"
echo "=================================================="
