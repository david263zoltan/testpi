#!/bin/bash
# JARVIS NODE OS v7.6 - PYENV PATH FIX
set -e

echo "=================================================="
echo "🚀 JARVIS NODE OS v7.6 - RASPBERRY PI INSTALLER"
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

echo "[1/9] 🔄 Rendszerfüggőségek ellenőrzése..."
apt-get update
apt-get install -y git cmake build-essential libusb-1.0-0-dev \
libfreenect-dev python3-dev cython3 libportaudio2 portaudio19-dev \
cabextract wget curl llvm libssl-dev zlib1g-dev \
libbz2-dev libreadline-dev libsqlite3-dev libncurses-dev xz-utils \
tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev libasound2-dev

echo "[2/9] 🐍 Pyenv környezet beállítása..."
if [ ! -d "$PYENV_ROOT" ]; then
    sudo -u "$REAL_USER" bash -c 'curl https://pyenv.run | bash'
fi

# Pyenv elérési utak rögzítése a jövőbeli újraindításokhoz
if ! grep -q "PYENV_ROOT" "${REAL_HOME}/.bashrc"; then
    echo "export PYENV_ROOT=\"$PYENV_ROOT\"" >> "${REAL_HOME}/.bashrc"
    echo "export PATH=\"\$PYENV_ROOT/bin:\$PATH\"" >> "${REAL_HOME}/.bashrc"
    echo "eval \"\$($PYENV_ROOT/bin/pyenv init -)\"" >> "${REAL_HOME}/.bashrc"
fi

echo "[3/9] 📦 Python $PYTHON_VERSION fordítása (Ez eltarthat egy ideig)..."
# Egy ideiglenes szkriptet csinálunk, hogy a subshell garantáltan lássa a Pyenv-et
cat > /tmp/jarvis_pyenv_install.sh << EOF
#!/bin/bash
set -e
export PYENV_ROOT="$PYENV_ROOT"
export PATH="\$PYENV_ROOT/bin:\$PATH"
eval "\$(\$PYENV_ROOT/bin/pyenv init -)"
if [ ! -d "\$PYENV_ROOT/versions/$PYTHON_VERSION" ]; then
    pyenv install -s $PYTHON_VERSION
fi
pyenv global $PYTHON_VERSION
EOF

chmod +x /tmp/jarvis_pyenv_install.sh
chown "$REAL_USER" /tmp/jarvis_pyenv_install.sh
# Futtatjuk az ideiglenes szkriptet
sudo -u "$REAL_USER" bash /tmp/jarvis_pyenv_install.sh
rm -f /tmp/jarvis_pyenv_install.sh

# Beállítjuk a fő szkriptben is a path-t a továbbiakhoz
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$($PYENV_ROOT/bin/pyenv init -)"

echo "[4/9] 🔌 Kinect udev szabályok..."
cat > /etc/udev/rules.d/51-kinect.rules << 'UDEV'
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ae", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ad", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02b0", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02be", MODE="0666"
SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02bf", MODE="0666"
UDEV
udevadm control --reload-rules && udevadm trigger

echo "[5/9] 🎮 Kinect Firmware és Feltöltő (BEÉPÍTETT FORRÁSKÓDBÓL)..."
mkdir -p /lib/firmware/kinect
cd /tmp

cat > kinect_upload_fw.c << 'EOF_C'
#include <stdio.h>
#include <stdlib.h>
#include <libusb-1.0/libusb.h>

int main(int argc, char *argv[]) {
    if (argc < 2) return 1;
    libusb_context *ctx = NULL;
    libusb_device_handle *dev_handle = NULL;
    if (libusb_init(&ctx) < 0) return 1;
    dev_handle = libusb_open_device_with_vid_pid(ctx, 0x045e, 0x02ad);
    if (!dev_handle) {
        printf("Kinect Bootloader (02ad) nem talalhato.\n");
        return 1;
    }
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
EOF_C

gcc kinect_upload_fw.c -o kinect_upload_fw -lusb-1.0
cp kinect_upload_fw /usr/local/bin/
chmod +x /usr/local/bin/kinect_upload_fw

FW_URL="https://download.microsoft.com/download/F/9/9/F99791F2-D5BE-478A-B77A-830AD14950C3/KinectSDK-v1.0-beta2-x86.msi"
if [ ! -f /lib/firmware/kinect/UACFirmware ]; then
    wget -q "$FW_URL" -O /tmp/KinectSDK.msi
    cabextract /tmp/KinectSDK.msi -F "UACFirmware.*" -d /tmp/
    mv /tmp/UACFirmware.* /lib/firmware/kinect/UACFirmware
    rm -f /tmp/KinectSDK.msi
fi

cat > "${SCRIPT_DIR}/upload_kinect_fw.sh" << 'FW'
#!/bin/bash
/usr/local/bin/kinect_upload_fw /lib/firmware/kinect/UACFirmware || true
FW
chmod +x "${SCRIPT_DIR}/upload_kinect_fw.sh"

cat > /etc/udev/rules.d/55-kinect-audio-fw.rules << EOF
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ad", RUN+="${SCRIPT_DIR}/upload_kinect_fw.sh"
EOF
udevadm control --reload-rules && udevadm trigger

echo "[6/9] 🔧 Virtuális környezet..."
mkdir -p "$PROJECT_DIR"
if [ ! -d "$PROJECT_DIR/env" ]; then
    sudo -u "$REAL_USER" bash -c "$PYENV_ROOT/versions/$PYTHON_VERSION/bin/python -m venv '$PROJECT_DIR/env'"
fi

echo "[7/9] 📚 Python csomagok telepítése..."
sudo -u "$REAL_USER" bash -c "
    source '$PROJECT_DIR/env/bin/activate'
    pip install --upgrade pip setuptools wheel
    pip install 'cython==0.29.37' 'numpy==1.26.4'
    pip install pyzmq 'opencv-python-headless<4.10' pyaudio flask duckduckgo-search
"

echo "[8/9] 🔨 Libfreenect driver fordítása..."
cd "$SCRIPT_DIR"
[ ! -d "libfreenect" ] && git clone https://github.com/OpenKinect/libfreenect.git
cd libfreenect/wrappers/python
rm -rf build/ freenect.c || true
sudo -u "$REAL_USER" bash -c "source '$PROJECT_DIR/env/bin/activate'; python setup.py install"

echo "[9/9] ⏰ Autostart beállítása..."
CRON_JOB="@reboot cd $PROJECT_DIR && $PROJECT_DIR/env/bin/python $PROJECT_DIR/sender.py >> $SCRIPT_DIR/jarvis_node.log 2>&1"
(sudo -u "$REAL_USER" crontab -l 2>/dev/null | grep -v "sender.py"; echo "$CRON_JOB") | sudo -u "$REAL_USER" crontab -

echo "=================================================="
echo "✅ KÉSZ! Nincs több halott link és path hiba."
echo "Indítsd újra a gépet: reboot"
echo "=================================================="
