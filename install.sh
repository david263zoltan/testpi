#!/bin/bash
# JARVIS NODE OS v7.2 - Absolute Path Pyenv Fix (PATH bug javítva)
set -e

echo "=================================================="
echo "🚀 JARVIS NODE OS v7.2 - RASPBERRY PI INSTALLER"
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

echo "[1/9] 🔄 Alapcsomagok ellenőrzése..."
apt-get update
apt-get install -y git cmake build-essential libusb-1.0-0-dev \
libfreenect-dev python3-dev cython3 libportaudio2 portaudio19-dev \
kinect-audio-setup cabextract wget curl llvm libssl-dev zlib1g-dev \
libbz2-dev libreadline-dev libsqlite3-dev libncurses-dev xz-utils \
tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev libasound2-dev

echo "[2/9] 🐍 Pyenv telepítése..."
if [ ! -d "$PYENV_ROOT" ]; then
    sudo -u "$REAL_USER" bash -c 'curl https://pyenv.run | bash'
fi

# Pyenv elérési utak rögzítése a .bashrc-ben
if ! grep -q "PYENV_ROOT" "${REAL_HOME}/.bashrc"; then
    echo "export PYENV_ROOT=\"$PYENV_ROOT\"" >> "${REAL_HOME}/.bashrc"
    echo "export PATH=\"\$PYENV_ROOT/bin:\$PATH\"" >> "${REAL_HOME}/.bashrc"
    echo "eval \"\$(pyenv init -)\"" >> "${REAL_HOME}/.bashrc"
fi

echo "[3/9] 📦 Python $PYTHON_VERSION fordítása..."
# JAVÍTVA: korábban a PATH szó szerinti '\$PYENV_ROOT/bin:\$PATH' stringre lett
# állítva (nem lett kifejtve az egymásba ágyazott idézőjelek/escape-ek miatt),
# emiatt a belső shell nem találta a "bash"-t (env: 'bash': No such file or directory).
# Megoldás: ideiglenes script fájlba írjuk ki a parancsokat, ahol a változók
# egyértelműen, egyszeri kifejtéssel kerülnek behelyettesítésre.
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
rm -f /tmp/jarvis_pyenv_install.sh

echo "[4/9] 🔌 Kinect udev szabályok..."
cat > /etc/udev/rules.d/51-kinect.rules << 'UDEV'
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ae", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ad", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02b0", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02be", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02bf", MODE="0666"
UDEV
udevadm control --reload-rules && udevadm trigger

echo "[5/9] 🎮 Kinect Firmware és Feltöltő..."
# A "kinect-audio-setup" apt csomag (feltéve az [1/9]-ben) már tartalmazza a
# kinect_upload_fw és kinect_fetch_fw parancsokat - nincs szükség GitHub
# clone-ra vagy manuális gcc fordításra (ami hitelesítést igényelt egy
# nem is létező/privát repo miatt).
mkdir -p /lib/firmware/kinect
if [ ! -f /lib/firmware/kinect/UACFirmware ]; then
    FW_URL="https://download.microsoft.com/download/F/9/9/F99791F2-D5BE-478A-B77A-830AD14950C3/KinectSDK-v1.0-beta2-x86.msi"
    wget -q "$FW_URL" -O /tmp/KinectSDK.msi
    cabextract /tmp/KinectSDK.msi -F "UACFirmware.*" -d /tmp/
    mv /tmp/UACFirmware.* /lib/firmware/kinect/UACFirmware
    rm -f /tmp/KinectSDK.msi
fi

cat > "${SCRIPT_DIR}/upload_kinect_fw.sh" << 'FW'
#!/bin/bash
kinect_upload_fw /lib/firmware/kinect/UACFirmware || true
FW
chmod +x "${SCRIPT_DIR}/upload_kinect_fw.sh"

echo "[6/9] 🔧 Virtuális környezet..."
mkdir -p "$PROJECT_DIR"
# A frissen telepített pyenv Python-t használjuk a venv-hez
sudo -u "$REAL_USER" bash -c "
    $PYENV_ROOT/versions/$PYTHON_VERSION/bin/python -m venv '$PROJECT_DIR/env'
"

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
sudo -u "$REAL_USER" bash -c "
    source '$PROJECT_DIR/env/bin/activate'
    python setup.py install
"

echo "[9/9] ⏰ Autostart beállítása..."
sudo -u "$REAL_USER" bash -c "(crontab -l 2>/dev/null | grep -v 'sender.py'; echo '@reboot cd $PROJECT_DIR && $PROJECT_DIR/env/bin/python $PROJECT_DIR/sender.py >> $SCRIPT_DIR/jarvis_node.log 2>&1') | crontab -"

echo "✅ TELEPÍTÉS KÉSZ! Reboot ajánlott."
