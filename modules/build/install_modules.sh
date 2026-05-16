#!/bin/sh
set -e

echo "=== 1. Eksisterende layout ==="
ls -la /lib/modules/3.16.0-karo/kernel/drivers/usb/

echo
echo "=== 2. Opprett kataloger ==="
mkdir -p /lib/modules/3.16.0-karo/kernel/drivers/usb/class
mkdir -p /lib/modules/3.16.0-karo/kernel/drivers/usb/serial
echo "  klasser: $(ls -d /lib/modules/3.16.0-karo/kernel/drivers/usb/class)"
echo "  serial:  $(ls -d /lib/modules/3.16.0-karo/kernel/drivers/usb/serial)"

echo
echo "=== 3. Kopier moduler ==="
cp /data/sd/cdc-acm-v6.ko /lib/modules/3.16.0-karo/kernel/drivers/usb/class/cdc-acm.ko
cp /data/sd/ch341-v6.ko /lib/modules/3.16.0-karo/kernel/drivers/usb/serial/ch341.ko
ls -la /lib/modules/3.16.0-karo/kernel/drivers/usb/class/cdc-acm.ko
ls -la /lib/modules/3.16.0-karo/kernel/drivers/usb/serial/ch341.ko

echo
echo "=== 4. depmod ==="
depmod -a 3.16.0-karo
echo "  depmod exit=$?"

echo
echo "=== 5. Verifiser modules.dep ==="
grep -E 'cdc-acm|ch341' /lib/modules/3.16.0-karo/modules.dep || echo "(ikke i dep-fil)"

echo
echo "=== 6. modprobe-test (dry run) ==="
modprobe -n -v cdc-acm 2>&1 || echo "modprobe cdc-acm feilet"
modprobe -n -v ch341 2>&1 || echo "modprobe ch341 feilet"

echo
echo "=== 7. Allerede lastet? ==="
/sbin/lsmod | grep -E 'cdc|acm|ch341|hello'

echo
echo "=== INSTALL FULLFØRT ==="
echo "Moduler vil lastes automatisk når enheter pluges inn (USB-hotplug)."
echo "For manuell lasting ved boot, legg til i /etc/init.d/ eller bruk modprobe."
