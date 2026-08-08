#!/bin/bash
set -e

echo "[1/3] Függőségek..."
sudo apt-get install -y build-essential libusb-1.0-0-dev usbutils

echo "[2/3] Páncélozott feltöltő fordítása..."
cat << 'EOF' > kinect_pancelozott.c
#include <stdio.h>
#include <stdlib.h>
#include <libusb-1.0/libusb.h>

int main(int argc, char *argv[]) {
    if (argc < 2) return 1;
    libusb_context *ctx = NULL;
    libusb_device_handle *dev_handle = NULL;
    
    libusb_init(&ctx);
    dev_handle = libusb_open_device_with_vid_pid(ctx, 0x045e, 0x02ad);
    
    if (!dev_handle) {
        printf("❌ Kinect (02ad) nem található. Vagy már kész, vagy nincs bedugva.\n");
        return 1;
    }

    printf("🔄 Hardveres USB RESET küldése...\n");
    libusb_reset_device(dev_handle); // Ez a kulcs a modern Linux ellen!
    
    // Várunk egy kicsit a reset után
    libusb_close(dev_handle);
    system("sleep 2"); 

    // Újra megnyitjuk
    dev_handle = libusb_open_device_with_vid_pid(ctx, 0x045e, 0x02ad);
    if (!dev_handle) {
        printf("❌ Eszköz elveszett a reset után.\n");
        return 1;
    }

    libusb_set_auto_detach_kernel_driver(dev_handle, 1);
    libusb_claim_interface(dev_handle, 0);

    FILE *fw = fopen(argv[1], "rb");
    fseek(fw, 0, SEEK_END); long fw_size = ftell(fw); fseek(fw, 0, SEEK_SET);
    unsigned char *buffer = malloc(fw_size); fread(buffer, 1, fw_size, fw); fclose(fw);
    
    int transferred;
    printf("Firmware küldése (%ld bájt)...\n", fw_size);
    int res = libusb_bulk_transfer(dev_handle, 1, buffer, fw_size, &transferred, 15000);
    
    if (res == 0) printf("✅ SIKER! Firmware feltöltve.\n");
    else printf("❌ HIBA: %d\n", res);

    libusb_release_interface(dev_handle, 0);
    libusb_close(dev_handle);
    libusb_exit(ctx);
    return 0;
}
EOF
gcc kinect_pancelozott.c -o kinect_pancelozott -lusb-1.0

echo "[3/3] Futattás..."
sudo ./kinect_pancelozott /lib/firmware/kinect/UACFirmware

echo "Ellenőrzés (lsusb):"
sleep 2
lsusb | grep Microsoft
