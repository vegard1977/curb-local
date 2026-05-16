#!/bin/sh
set -e

echo "=== 1. Kopier cp210x.ko til /lib/modules/ ==="
cp /data/sd/cp210x.ko /lib/modules/3.16.0-karo/kernel/drivers/usb/serial/cp210x.ko
ls -la /lib/modules/3.16.0-karo/kernel/drivers/usb/serial/

echo
echo "=== 2. Oppdater S35cdc-modules til ogsa cp210x ==="
cat > /etc/init.d/S35cdc-modules << 'EOF'
#!/bin/sh
# S35cdc-modules -- laster USB-serial drivere ved boot
# cdc_acm = USB CDC (Arduino Uno/Mega, ESP32-S2/S3 m/native USB)
# ch341   = CH340G (klone-brett, billige Arduino Nano)
# cp210x  = Silicon Labs CP2102 (originale ESP32 dev-boards)

CDC=/lib/modules/3.16.0-karo/kernel/drivers/usb/class/cdc-acm.ko
CH341=/lib/modules/3.16.0-karo/kernel/drivers/usb/serial/ch341.ko
CP210X=/lib/modules/3.16.0-karo/kernel/drivers/usb/serial/cp210x.ko

case "$1" in
  start)
    /sbin/lsmod | grep -q '^cdc_acm ' || /sbin/insmod $CDC
    /sbin/lsmod | grep -q '^ch341 '   || /sbin/insmod $CH341
    /sbin/lsmod | grep -q '^cp210x '  || /sbin/insmod $CP210X
    ;;
  stop)
    /sbin/lsmod | grep -q '^cp210x '  && /sbin/rmmod cp210x
    /sbin/lsmod | grep -q '^ch341 '   && /sbin/rmmod ch341
    /sbin/lsmod | grep -q '^cdc_acm ' && /sbin/rmmod cdc_acm
    ;;
  *)
    echo "Usage: $0 {start|stop}"
    exit 1
    ;;
esac
exit 0
EOF
chmod +x /etc/init.d/S35cdc-modules
cat /etc/init.d/S35cdc-modules

echo
echo "=== 3. Test init-script (stop alle, start alle) ==="
/etc/init.d/S35cdc-modules stop
echo "  etter stop:"
/sbin/lsmod | grep -E 'cdc|ch341|cp210' || echo "    (ingen lastet)"
/etc/init.d/S35cdc-modules start
echo "  etter start:"
/sbin/lsmod | grep -E 'cdc|ch341|cp210'

echo
echo "=== 4. Verifiser tty-devices ==="
ls /dev/ttyACM* /dev/ttyUSB* 2>&1

echo
echo "=== INSTALL FULLFORT ==="
