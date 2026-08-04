#!/bin/bash

# Hiba esetén azonnali leállás
set -e

echo "=================================================="
echo "🚀 JARVIS NODE OS v6.0 - TELJES RENDSZERTELEPÍTŐ"
echo "=================================================="

# --- VÁLTOZÓK ---
PYTHON_VERSION="3.12.3"
USER_HOME=$(eval echo ~$USER)
PROJECT_DIR="$USER_HOME/pi_node"

echo "[1/10] SWAP Memória növelése (2GB) a fordításhoz..."
sudo dphys-swapfile swapoff || true
sudo sed -i 's/CONF_SWAPSIZE=.*/CONF_SWAPSIZE=2048/' /etc/dphys-swapfile
sudo dphys-swapfile setup
sudo dphys-swapfile swapon

echo "[2/10] Rendszerfüggőségek telepítése (Kinect + Audio + hálózat)..."
sudo apt update
sudo apt install -y git cmake build-essential libusb-1.0-0-dev \
libfreenect-dev python3-dev cython3 libportaudio2 portaudio19-dev \
kinect-audio-setup cabextract wget curl llvm libssl-dev zlib1g-dev \
libbz2-dev libreadline-dev libsqlite3-dev libncurses-dev xz-utils \
tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev libasound2-dev

echo "[3/10] Pyenv és Python $PYTHON_VERSION telepítése..."
if [ -d "$HOME/.pyenv" ]; then
    echo "Pyenv már telepítve."
else
    curl https://pyenv.run | bash
fi

# Környezet beállítása az aktuális terminálhoz
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"

if ! grep -q 'PYENV_ROOT' "$HOME/.bashrc"; then
    echo 'export PYENV_ROOT="$HOME/.pyenv"' >> "$HOME/.bashrc"
    echo '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"' >> "$HOME/.bashrc"
    echo 'eval "$(pyenv init -)"' >> "$HOME/.bashrc"
fi

echo "Python $PYTHON_VERSION fordítása (ez a Pi 3B-n kb. 15-20 perc)..."
pyenv install -s "$PYTHON_VERSION"
pyenv global "$PYTHON_VERSION"

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

echo "[6/10] Firmware feltöltő scriptek generálása..."
cat << 'EOF' > "$USER_HOME/upload_kinect_fw.sh"
#!/bin/bash
FIRMWARE_PATH="/lib/firmware/kinect/UACFirmware"
sudo kinect_upload_fw "$FIRMWARE_PATH" || echo "Firmware már betöltve vagy hiba."
EOF
chmod +x "$USER_HOME/upload_kinect_fw.sh"

# Hotplug szabály a mikrofonhoz
sudo bash -c "cat << EOF > /etc/udev/rules.d/55-kinect-audio-fw.rules
ACTION==\"add\", SUBSYSTEM==\"usb\", ATTR{idVendor}==\"045e\", ATTR{idProduct}==\"02ad\", RUN+=\"$USER_HOME/upload_kinect_fw.sh\"
EOF"
sudo udevadm control --reload-rules && sudo udevadm trigger

echo "[7/10] Virtuális környezet (venv) létrehozása..."
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"
python -m venv env
source env/bin/activate

echo "[8/10] SENDER.PY függőségek telepítése (Ubuntu szinkron)..."
pip install --upgrade pip
pip install "cython==0.29.37" "numpy==1.26.4"
pip install pyzmq "opencv-python-headless<4.10" pyaudio flask

echo "[9/10] Freenect Python driver fordítása forrásból..."
cd "$USER_HOME"
if [ -d "libfreenect" ]; then rm -rf libfreenect; fi
git clone https://github.com/OpenKinect/libfreenect.git
cd libfreenect/wrappers/python
rm -rf build/
[ -f freenect.c ] && rm freenect.c
python setup.py install

echo "[10/10] Automatikus indítás (Cron job) beállítása..."
(crontab -l 2>/dev/null | grep -v "sender.py"; echo "@reboot cd $PROJECT_DIR && env/bin/python sender.py >> $USER_HOME/jarvis_node.log 2>&1") | crontab -

echo "=================================================="
echo "✅ TELEPÍTÉS SIKERES!"
echo "Python verzió: $(python --version)"
echo "--------------------------------------------------"
echo "A használathoz:"
echo "1. cd $PROJECT_DIR"
echo "2. source env/bin/activate"
echo "3. Másold ide a 'sender.py' fájlt."
echo "4. python sender.py"
echo "=================================================="
