#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <libusb-1.0/libusb.h>

int main(int argc, char *argv[]) {
    if (argc < 2) return 1;
    libusb_context *ctx = NULL;
    libusb_device_handle *dev_handle = NULL;
    libusb_init(&ctx);

    printf("Várakozás a Kinectre (02ad)...\n");
    
    // 1. CIKLUS: Megvárjuk, amíg egyáltalán megjelenik
    while (!dev_handle) {
        dev_handle = libusb_open_device_with_vid_pid(ctx, 0x045e, 0x02ad);
        if (!dev_handle) {
            usleep(500000); // 0.5 mp várakozás
        }
    }

    printf("🔄 Eszköz megtalálva. Reset és kényszerített átvétel...\n");
    libusb_reset_device(dev_handle);
    libusb_close(dev_handle);
    dev_handle = NULL;

    // 2. CIKLUS: Reset után megpróbáljuk visszaszerezni a kerneltől
    for (int i = 0; i < 20; i++) {
        usleep(500000);
        dev_handle = libusb_open_device_with_vid_pid(ctx, 0x045e, 0x02ad);
        if (dev_handle) {
            // Megpróbáljuk leválasztani a kernelt, ha már ráugrott volna
            libusb_set_auto_detach_kernel_driver(dev_handle, 1);
            if (libusb_claim_interface(dev_handle, 0) == 0) {
                printf("✅ Sikerült visszaszerezni az eszközt a %d. próbálkozásra!\n", i);
                break;
            }
            libusb_close(dev_handle);
            dev_handle = NULL;
        }
    }

    if (!dev_handle) {
        printf("❌ Nem sikerült visszaszerezni az eszközt.\n");
        return 1;
    }

    FILE *fw = fopen(argv[1], "rb");
    fseek(fw, 0, SEEK_END); long fw_size = ftell(fw); fseek(fw, 0, SEEK_SET);
    unsigned char *buffer = malloc(fw_size); fread(buffer, 1, fw_size, fw); fclose(fw);
    
    int transferred;
    printf("Firmware küldése (%ld bájt)...\n", fw_size);
    int res = libusb_bulk_transfer(dev_handle, 1, buffer, fw_size, &transferred, 15000);
    
    if (res == 0) printf("🎉 GRATULÁLOK! SIKERES FELTÖLTÉS!\n");
    else printf("❌ Hiba: %d\n", res);

    libusb_release_interface(dev_handle, 0);
    libusb_close(dev_handle);
    libusb_exit(ctx);
    return 0;
}
