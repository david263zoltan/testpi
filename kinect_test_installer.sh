#!/bin/bash
# KINECT V1 FIRMWARE TESTER & INSTALLER FOR LINUX

set -e

echo "-------------------------------------------------------"
echo "🔍 KINECT V1 FIRMWARE TESZTELŐ ESZKÖZ"
echo "-------------------------------------------------------"

# 1. CSOMAGKEZELŐ FELISMERÉSE ÉS FÜGGŐSÉGEK
echo "[1/5] Függőségek ellenőrzése és telepítése..."

if [ -f /etc/debian_version ]; then
    # Debian, Ubuntu, DietPi, Raspberry Pi OS, Mint
    sudo apt-get update
    sudo apt-get install -y build-essential libusb-1.0-0-dev wget p7zip-full usbutils
elif [ -f /etc/fedora-release ]; then
    # Fedora
    sudo dnf install -y gcc gcc-c++ libusb1-devel wget p7zip usbutils
elif [ -f /etc/arch-release ]; then
    # Arch Linux, Manjaro
    sudo pacman -Sy --noconfirm base-devel libusb wget p7zip usbutils
else
    echo "❌ Ismeretlen disztribúció! Kérlek telepítsd kézzel: libusb-1.0, gcc, wget, 7zip"
fi

# 2. FIRMWARE KINYERÉSE
echo "[2/5] Firmware letöltése a Microsofttól..."
mkdir -p /tmp/kinect_test
cd /tmp/kinect_test
wget -q "https://download.microsoft.com/download/F/9/9/F99791F2-D5BE-478A-B77A-830AD14950C3/KinectSDK-v1.0-beta2-x86.msi" -O KinectSDK.msi
7z e KinectSDK.msi "UACFirmware.*" -r -y > /dev/null
sudo mkdir -p /lib/firmware/kinect
sudo mv UACFirmware.* /lib/firmware/kinect/UACFirmware
echo "✅ Firmware előkészítve: /lib/firmware/kinect/UACFirmware"

# 3. FELTÖLTŐ PROGRAM FORDÍTÁSA
echo "[3/5] C-alapú feltöltő fordítása..."
cat << 'EOF' > kinect_upload_fw.c
#include <stdio.h>
#include <stdlib.h>
#include <libusb-1.0/libusb.h>
int main(int argc, char *argv[]) {
    if (argc < 2) { printf("Használat: %s <firmware_fájl>\n", argv[0]); return 1; }
    libusb_context *ctx = NULL;
    libusb_device_handle *dev_handle = NULL;
    if (libusb_init(&ctx) < 0) { printf("Libusb init hiba!\n"); return 1; }
    dev_handle = libusb_open_device_with_vid_pid(ctx, 0x045e, 0x02ad);
    if (!dev_handle) { printf("❌ Kinect Bootloader (02ad) NEM található!\n"); return 1; }
    FILE *fw = fopen(argv[1], "rb");
    if (!fw) { printf("Firmware fájl hiba!\n"); return 1; }
    fseek(fw, 0, SEEK_END); long fw_size = ftell(fw); fseek(fw, 0, SEEK_SET);
    unsigned char *buffer = malloc(fw_size); fread(buffer, 1, fw_size, fw); fclose(fw);
    int transferred;
    printf("Firmware küldése (%ld bájt)...\n", fw_size);
    int res = libusb_bulk_transfer(dev_handle, 1, buffer, fw_size, &transferred, 10000);
    if (res == 0) printf("✅ SIKERES FELTÖLTÉS!\n");
    else printf("❌ HIBA a küldés során: %d\n", res);
    free(buffer); libusb_close(dev_handle); libusb_exit(ctx);
    return res;
}
EOF
gcc kinect_upload_fw.c -o kinect_upload_fw -lusb-1.0
sudo cp kinect_upload_fw /usr/local/bin/

# 4. UDEV SZABÁLYOK A TESZTHEZ
echo "[4/5] Automatikus szabályok beállítása..."
sudo bash -c "cat << 'UDEV' > /etc/udev/rules.d/55-kinect-test.rules
SUBSYSTEM==\"usb\", ATTR{idVendor}==\"045e\", ATTR{idProduct}==\"02ad\", MODE=\"0666\", RUN+=\"/usr/local/bin/kinect_upload_fw /lib/firmware/kinect/UACFirmware\"
SUBSYSTEM==\"usb\", ATTR{idVendor}==\"045e\", ATTR{idProduct}==\"02ae\", MODE=\"0666\"
SUBSYSTEM==\"usb\", ATTR{idVendor}==\"045e\", ATTR{idProduct}==\"02be\", MODE=\"0666\"
SUBSYSTEM==\"usb\", ATTR{idVendor}==\"045e\", ATTR{idProduct}==\"02bf\", MODE=\"0666\"
UDEV"
sudo udevadm control --reload-rules
sudo udevadm trigger

# 5. TESZTELÉS
echo "-------------------------------------------------------"
echo "[5/5] TESZT INDÍTÁSA..."
echo "Kérlek húzd ki, majd dugd vissza a Kinectet!"
echo "Várakozás az eszközre..."

for i in {1..10}; do
    if lsusb | grep -q "045e:02be" || lsusb | grep -q "045e:02bf"; then
        echo "🎉 GRATULÁLOK! A firmware sikeresen betöltődött."
        echo "A Kinect Audio most már látható a rendszerben:"
        lsusb | grep Microsoft
        exit 0
    fi
    sleep 2
    echo "...még nem észlelem ($i/10)"
done

echo "❌ A teszt sikertelen. Lehetséges okok:"
echo "1. Nem kap elég áramot az eszköz (Undervoltage)."
echo "2. A Linux gyári drivere (gspca_kinect) blokkolja az USB-t."
echo "3. Rossz az USB kábel."
