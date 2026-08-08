#!/bin/bash
set -e

echo "-------------------------------------------------------"
echo "🔍 KINECT V1 UNIVERZÁLIS TESZTELŐ ÉS TELEPÍTŐ v2.0"
echo "-------------------------------------------------------"

# 1. CSOMAGKEZELŐ ÉS FÜGGŐSÉGEK
echo "[1/6] Függőségek telepítése..."
if [ -f /etc/debian_version ]; then
    sudo apt-get update
    sudo apt-get install -y build-essential libusb-1.0-0-dev wget p7zip-full usbutils
elif [ -f /etc/fedora-release ]; then
    sudo dnf install -y gcc gcc-c++ libusb1-devel wget p7zip usbutils
elif [ -f /etc/arch-release ]; then
    sudo pacman -Sy --noconfirm base-devel libusb wget p7zip usbutils
fi

# 2. ZAVARÓ DRIVEREK ELTÁVOLÍTÁSA (Zorin/Ubuntu/PC esetén kritikus)
echo "[2/6] Gyári driverek (gspca_kinect) tiltása..."
sudo modprobe -r gspca_kinect 2>/dev/null || true
sudo bash -c "cat << 'EOF' > /etc/modprobe.d/blacklist-kinect-test.conf
blacklist gspca_kinect
blacklist gspca_main
EOF"

# 3. FIRMWARE ELŐKÉSZÍTÉSE
echo "[3/6] Firmware kinyerése a Microsoft SDK-ból..."
sudo mkdir -p /lib/firmware/kinect
cd /tmp
rm -f KinectSDK.msi UACFirmware*
wget -q "https://download.microsoft.com/download/F/9/9/F99791F2-D5BE-478A-B77A-830AD14950C3/KinectSDK-v1.0-beta2-x86.msi" -O KinectSDK.msi
7z e KinectSDK.msi "UACFirmware.*" -r -y > /dev/null
sudo mv UACFirmware.* /lib/firmware/kinect/UACFirmware
sudo chmod 644 /lib/firmware/kinect/UACFirmware

# 4. A C-ALAPÚ FELTÖLTŐ PROGRAM ÖSSZERAKÁSA
echo "[4/6] kinect_upload_fw fordítása és telepítése..."
cat << 'EOF' > kinect_upload_fw.c
#include <stdio.h>
#include <stdlib.h>
#include <libusb-1.0/libusb.h>
int main(int argc, char *argv[]) {
    if (argc < 2) { printf("Használat: %s <firmware_path>\n", argv[0]); return 1; }
    libusb_context *ctx = NULL;
    libusb_device_handle *dev_handle = NULL;
    if (libusb_init(&ctx) < 0) return 1;
    // Megnyitjuk a Kinect Bootloader-t (045e:02ad)
    dev_handle = libusb_open_device_with_vid_pid(ctx, 0x045e, 0x02ad);
    if (!dev_handle) { printf("❌ Kinect Bootloader (02ad) nem található!\n"); return 1; }
    
    FILE *fw = fopen(argv[1], "rb");
    if (!fw) { printf("❌ Firmware fájl hiba!\n"); return 1; }
    fseek(fw, 0, SEEK_END); long fw_size = ftell(fw); fseek(fw, 0, SEEK_SET);
    unsigned char *buffer = malloc(fw_size); fread(buffer, 1, fw_size, fw); fclose(fw);
    
    int transferred;
    printf("Küldés: %ld bájt...\n", fw_size);
    int res = libusb_bulk_transfer(dev_handle, 1, buffer, fw_size, &transferred, 10000);
    if (res == 0) printf("✅ SIKER! Firmware feltöltve.\n");
    else printf("❌ Hiba a feltöltésnél: %d\n", res);
    
    free(buffer); libusb_close(dev_handle); libusb_exit(ctx);
    return res;
}
EOF
gcc kinect_upload_fw.c -o kinect_upload_fw -lusb-1.0
sudo cp kinect_upload_fw /usr/local/bin/
sudo chmod +x /usr/local/bin/kinect_upload_fw

# 5. UDEV SZABÁLYOK BEÁLLÍTÁSA (Hogy magától elinduljon)
echo "[5/6] Udev automatizmus beállítása..."
sudo bash -c "cat << 'UDEV' > /etc/udev/rules.d/55-kinect-test.rules
ACTION==\"add\", SUBSYSTEM==\"usb\", ATTR{idVendor}==\"045e\", ATTR{idProduct}==\"02ad\", RUN+=\"/usr/local/bin/kinect_upload_fw /lib/firmware/kinect/UACFirmware\"
SUBSYSTEM==\"usb\", ATTR{idVendor}==\"045e\", ATTR{idProduct}==\"02ae\", MODE=\"0666\"
SUBSYSTEM==\"usb\", ATTR{idVendor}==\"045e\", ATTR{idProduct}==\"02be\", MODE=\"0666\"
SUBSYSTEM==\"usb\", ATTR{idVendor}==\"045e\", ATTR{idProduct}==\"02bf\", MODE=\"0666\"
UDEV"
sudo udevadm control --reload-rules && sudo udevadm trigger

# 6. AZONNALI ELLENŐRZÉS
echo "-------------------------------------------------------"
echo "[6/6] TESZTELÉS INDÍTÁSA..."
echo "Próbálkozás a manuális indítással..."
sudo /usr/local/bin/kinect_upload_fw /lib/firmware/kinect/UACFirmware || true

echo "Várakozás az eszközre (10mp)..."
sleep 5
if lsusb | grep -qE "02be|02bf"; then
    echo "🎉 SIKER! A Kinect audió eszközként látható:"
    lsusb | grep Microsoft
else
    echo "❌ Még mindig nem észlelhető a firmware feltöltése után."
    echo "Tipp: Húzd ki az USB-t, majd dugd vissza!"
fi
