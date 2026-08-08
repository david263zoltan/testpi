#!/bin/bash
set -e

echo "=================================================="
echo "🚀 KINECT FIRMWARE UPLOADER - FRISS TELEPÍTÉS"
echo "=================================================="

# 1. RENDSZERFÜGGŐSÉGEK TELEPÍTÉSE
echo "[1/5] Alapcsomagok telepítése (Fordító + USB könyvtárak)..."
# Megnézzük a csomagkezelőt (Debian/Ubuntu/Zorin/DietPi alapokon apt)
sudo apt-get update
sudo apt-get install -y build-essential libusb-1.0-0-dev wget p7zip-full usbutils

# 2. FIRMWARE KINYERÉSE
echo "[2/5] Microsoft SDK letöltése és firmware kinyerése..."
sudo mkdir -p /lib/firmware/kinect
cd /tmp
rm -f KinectSDK.msi UACFirmware*
wget -q "https://download.microsoft.com/download/F/9/9/F99791F2-D5BE-478A-B77A-830AD14950C3/KinectSDK-v1.0-beta2-x86.msi" -O KinectSDK.msi
7z e KinectSDK.msi "UACFirmware.*" -r -y > /dev/null
sudo mv UACFirmware.* /lib/firmware/kinect/UACFirmware
sudo chmod 644 /lib/firmware/kinect/UACFirmware
echo "✅ Firmware mentve: /lib/firmware/kinect/UACFirmware"

# 3. A C-KÓD MEGÍRÁSA (A legstabilabb, várakozó verzió)
echo "[3/5] Feltöltő forráskód (kinect_upload.c) elkészítése..."
cat << 'EOF' > kinect_upload.c
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <libusb-1.0/libusb.h>

int main(int argc, char *argv[]) {
    if (argc < 2) { printf("Használat: %s <firmware_fájl>\n", argv[0]); return 1; }
    libusb_context *ctx = NULL;
    libusb_device_handle *dev_handle = NULL;
    libusb_init(&ctx);

    printf("🔍 Keresem a Kinectet (02ad)... ");
    dev_handle = libusb_open_device_with_vid_pid(ctx, 0x045e, 0x02ad);
    
    if (!dev_handle) {
        printf("Nincs bedugva vagy már fel van töltve.\n");
        return 1;
    }
    printf("Megvan!\n");

    // Kernel driver leválasztása (hogy ne legyen Busy hiba)
    libusb_set_auto_detach_kernel_driver(dev_handle, 1);
    libusb_claim_interface(dev_handle, 0);

    FILE *fw = fopen(argv[1], "rb");
    if (!fw) { printf("❌ Firmware fájl nem olvasható!\n"); return 1; }
    
    fseek(fw, 0, SEEK_END); long fw_size = ftell(fw); fseek(fw, 0, SEEK_SET);
    unsigned char *buffer = malloc(fw_size); fread(buffer, 1, fw_size, fw); fclose(fw);
    
    int transferred;
    printf("🚀 Firmware küldése (%ld bájt)...\n", fw_size);
    int res = libusb_bulk_transfer(dev_handle, 1, buffer, fw_size, &transferred, 15000);
    
    if (res == 0) printf("✅ SIKERES FELTÖLTÉS!\n");
    else printf("❌ HIBA: %d\n", res);

    libusb_release_interface(dev_handle, 0);
    libusb_close(dev_handle);
    libusb_exit(ctx);
    return res;
}
EOF

# 4. FORDÍTÁS
echo "[4/5] Program fordítása (gcc)..."
gcc kinect_upload.c -o kinect_upload -lusb-1.0
sudo cp kinect_upload /usr/local/bin/kinect_upload_fw
sudo chmod +x /usr/local/bin/kinect_upload_fw

# 5. UDEV SZABÁLYOK (Hogy bedugáskor magától lefusson)
echo "[5/5] Automatikus indítás (udev) beállítása..."
sudo bash -c "cat << 'UDEV' > /etc/udev/rules.d/55-kinect.rules
ACTION==\"add\", SUBSYSTEM==\"usb\", ATTR{idVendor}==\"045e\", ATTR{idProduct}==\"02ad\", RUN+=\"/usr/local/bin/kinect_upload_fw /lib/firmware/kinect/UACFirmware\"
SUBSYSTEM==\"usb\", ATTR{idVendor}==\"045e\", ATTR{idProduct}==\"02ae\", MODE=\"0666\"
SUBSYSTEM==\"usb\", ATTR{idVendor}==\"045e\", ATTR{idProduct}==\"02be\", MODE=\"0666\"
SUBSYSTEM==\"usb\", ATTR{idVendor}==\"045e\", ATTR{idProduct}==\"02bf\", MODE=\"0666\"
UDEV"

sudo udevadm control --reload-rules
sudo udevadm trigger

echo "--------------------------------------------------"
echo "✅ MINDEN KÉSZ!"
echo "Most dugd be a Kinectet, és írd be: lsusb | grep Microsoft"
echo "Ha manuálisan akarod futtatni: sudo kinect_upload_fw /lib/firmware/kinect/UACFirmware"
echo "--------------------------------------------------"
