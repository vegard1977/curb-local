# Curb Kernel Modules

Pre-compiled Linux 3.16 kernel modules for the **Curb Energy Monitor** (NXP i.MX28, ARMv5, vermagic `3.16.0-karo`).

Load and manage modules from the browser via `http://<curb-ip>/modules.html`, or manually via SSH.

---

## Available modules

| File | Driver | Size | Purpose |
|------|--------|------|---------|
| `cdc-acm.ko` | cdc_acm | 36 KB | Arduino Uno/Mega, ESP32-S2/S3 native USB, USB modems |
| `ch341.ko` | ch341 | 11 KB | CH340G clone boards (cheap Arduino Nano) |
| `cp210x.ko` | cp210x | 13 KB | Silicon Labs CP2102/CP2104 (original ESP32 dev-boards) |
| `usbserial.ko` | usbserial | 46 KB | USB serial core (usually built-in on Curb, included as fallback) |
| `usb-storage-ref.ko` | usb-storage | 77 KB | Reference copy extracted from Curb — for comparison |
| `hello.ko` | — | 3 KB | Test module (printk only) |
| `hello2.ko` | — | 3 KB | Minimal test module (no kernel API) |

---

## Supported USB devices

| Device | Driver | Node |
|--------|--------|------|
| Arduino Uno (Genuino R3) | cdc_acm | `/dev/ttyACM0` |
| Arduino Mega 2560 | cdc_acm | `/dev/ttyACM0` |
| Arduino Nano (CH340 clone) | ch341 | `/dev/ttyUSB0` |
| Arduino Nano (FTDI) | ftdi_sio (built-in) | `/dev/ttyUSB0` |
| ESP32 dev-board (CP2102/CP2104) | cp210x | `/dev/ttyUSB0` |
| ESP32-S2/S3 native USB | cdc_acm | `/dev/ttyACM0` |
| USB modem (3G/4G) | cdc_acm | `/dev/ttyACM0` |

---

## Install via browser

Open `http://<curb-ip>/modules.html` — upload `.ko` files and toggle boot persistence from the browser.

---

## Manual install via SSH

```sh
# Copy a module to the device
scp -i ~/.ssh/id_rsa_curb -o PubkeyAcceptedAlgorithms=+ssh-rsa \
    modules/bin/cdc-acm.ko root@<curb-ip>:/data/sd/

# Install to kernel module path
ssh root@<curb-ip> "mkdir -p /lib/modules/3.16.0-karo/kernel/drivers/usb/class && \
    cp /data/sd/cdc-acm.ko /lib/modules/3.16.0-karo/kernel/drivers/usb/class/"

# Load immediately
ssh root@<curb-ip> "insmod /lib/modules/3.16.0-karo/kernel/drivers/usb/class/cdc-acm.ko"

# Verify
ssh root@<curb-ip> "lsmod | grep cdc"
```

---

## Manual load / unload

```sh
# Load
insmod /lib/modules/3.16.0-karo/kernel/drivers/usb/class/cdc-acm.ko
insmod /lib/modules/3.16.0-karo/kernel/drivers/usb/serial/ch341.ko
insmod /lib/modules/3.16.0-karo/kernel/drivers/usb/serial/cp210x.ko

# Unload
rmmod cp210x
rmmod ch341
rmmod cdc_acm

# Check loaded
lsmod | grep -E 'cdc|ch341|cp210x'
ls /dev/ttyACM* /dev/ttyUSB*
```
