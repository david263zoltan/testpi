#!/bin/bash
set -e

echo "-------------------------------------------------------"
echo "🔍 KINECT V1 TESZTELŐ v2.1 - ERROR -9 JAVÍTÁSSAL"
echo "-------------------------------------------------------"

# 1. ELŐKÉSZÜLETEK
sudo apt-get update && sudo apt-get install -y build-essential libusb-1.0-0-dev wget p7zip-full usbutils

# 2. DRIVER KILLER (Még erőszakosabban)
echo "[1/4] Kernel driverek kényszerített leállítása..."
sudo modprobe -r gspca_kinect 2>/dev/null || true
sudo modprobe -r gspca_main 2>/dev/null || true

# 3. FIRMWARE ELLENŐRZÉSE
sudo mkdir -p /lib/firmware/kinect
if [ ! -f /lib/firmware/kinect/UACFirmware ]; then
    echo "Firmware letöltése..."
    cd /tmp
    wget -q "https://download.microsoft.com/download/F/9/9/F99791F2-D5BE-478A-B77A-830AD14950C3/KinectSDK-v1.0-beta2-x86.msi" -O KinectSDK.msi
    7z e KinectSDK.msi "UACFirmware.*" -r -y > /dev/null
    sudo mv UACFirmware.* /lib/firmware/kinect/UACFirmware
fi

# 4. A JAVÍTOTT C-KÓD (Kényszerített leválasztással)
echo "[2/4] kinect_upload_fw fordítása speciális javítással..."
cat << 'EOF' > kinect_upload_fw.c
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
        printf("❌ Kinect nem található Bootloader módban (02ad).\n");
        return 1;
    }

    // --- JAVÍTÁS AZ ERROR -9 ELLEN ---
    // 1. Megkérjük a kernelt, hogy engedje el az eszközt
    if (libusb_kernel_driver_active(dev_handle, 0) == 1) {
        printf("Kernel driver leválasztása...\n");
        libusb_detach_kernel_driver(dev_handle, 0);
    }

    // 2. Lefoglaljuk az interfészt saját használatra
    libusb_claim_interface(dev_handle, 0);

    FILE *fw = fopen(argv[1], "rb");
    fseek(fw, 0, SEEK_END); long fw_size = ftell(fw); fseek(fw, 0, SEEK_SET);
    unsigned char *buffer = malloc(fw_size); fread(buffer, 1, fw_size, fw); fclose(fw);
    
    int transferred;
    printf("Firmware küldése (%ld bájt)...\n", fw_size);
    
    // 3. Adatküldés
    int res = libusb_bulk_transfer(dev_handle, 1, buffer, fw_size, &transferred, 10000);
    
    if (res == 0) printf("✅ SIKER! Firmware feltöltve.\n");
    else {
        printf("❌ HIBA: %d (Ha -9, akkor az USB port blokkolja).\n", res);
        printf("Tipp: Próbáld másik USB portba dugni!\n");
    }

    libusb_release_interface(dev_handle, 0);
    libusb_close(dev_handle);
    libusb_exit(ctx);
    return res;
}
EOF
gcc kinect_upload_fw.c -o kinect_upload_fw -lusb-1.0
sudo cp kinect_upload_fw /usr/local/bin/

# 5. FUTTATÁS
echo "[3/4] Feltöltés megkísérlése..."
sudo /usr/local/bin/kinect_upload_fw /lib/firmware/kinect/UACFirmware

echo "[4/4] Ellenőrzés..."
sleep 2
lsusb | grep Microsoft
