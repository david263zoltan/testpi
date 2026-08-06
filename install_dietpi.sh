#!/bin/bash
set -e

echo "=================================================="
echo "🚀 JARVIS DIETPI INSTALLER v9.0"
echo "=================================================="

# 1. USB ÁRAMERŐSSÉG MAXIMALIZÁLÁSA
echo "[1/11] USB áramkorlát feloldása (max_usb_current=1)..."
CONFIG_PATH="/boot/config.txt"
[ ! -f "$CONFIG_PATH" ] && CONFIG_PATH="/boot/firmware/config.txt"

if grep -q "max_usb_current" "$CONFIG_PATH"; then
    sed -i 's/max_usb_current=.*/max_usb_current=1/' "$CONFIG_PATH"
else
    echo "max_usb_current=1" >> "$CONFIG_PATH"
fi

# 2. DIETPI SPECIFIKUS CSOMAGOK
echo "[2/11] Alapcsomagok telepítése (DietPi-re)..."
apt-get update
apt-get install -y usbutils sudo git cmake build-essential libusb-1.0-0-dev \
libfreenect-dev python3-dev cython3 libportaudio2 portaudio19-dev \
wget curl p7zip-full libasound2-dev

# 3. KINECT FIRMWARE ÉS ESZKÖZÖK (A korábbi logikával)
echo "[3/11] Kinect Firmware és udev szabályok..."
mkdir -p /lib/firmware/kinect
cd /tmp
wget -q "https://download.microsoft.com/download/F/9/9/F99791F2-D5BE-478A-B77A-830AD14950C3/KinectSDK-v1.0-beta2-x86.msi" -O KinectSDK.msi
7z e KinectSDK.msi "UACFirmware.*" -r -y > /dev/null
mv UACFirmware.* /lib/firmware/kinect/UACFirmware
chmod 644 /lib/firmware/kinect/UACFirmware

# C-kód feltöltő fordítása
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

# .sh feltöltő
cat << 'FW_SH' > /usr/local/bin/kinect_full_init.sh
#!/bin/bash
/usr/local/bin/kinect_upload_fw /lib/firmware/kinect/UACFirmware || true
FW_SH
chmod +x /usr/local/bin/kinect_full_init.sh

# Udev szabály
cat << 'EOF_RULES' > /etc/udev/rules.d/55-kinect-audio-fw.rules
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ad", RUN+="/usr/local/bin/kinect_full_init.sh"
EOF_RULES
udevadm control --reload-rules && udevadm trigger

# 4. PYTHON KÖRNYEZET (Venv helyett DietPi-n mehet globálisan is, de maradjunk a venv-nél a tisztaság miatt)
PROJECT_DIR="/root/testpi/pi_node"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"
python3 -m venv env
source env/bin/activate
pip install --upgrade pip
pip install "cython==0.29.37" "numpy==1.26.4" pyzmq "opencv-python-headless<4.10" pyaudio flask

echo "Kész. Kérlek futtasd az install.sh többi részét vagy másold be a sender.py-t!"
