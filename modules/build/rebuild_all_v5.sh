#!/bin/bash
set -e
cd /home/qfh/curb-build/karo-tx-linux

# Verifiser at utsrelease er korrekt
cat include/generated/utsrelease.h

GCC=arm-linux-gnueabi-gcc
LD=arm-linux-gnueabi-ld
NM=arm-linux-gnueabi-nm

# FIXED BASE: -DCC_HAVE_ASM_GOTO lagt til. Også beholder vi -funwind-tables (matchet ref).
BASE="-nostdinc -isystem /usr/lib/gcc-cross/arm-linux-gnueabi/14/include \
  -I./arch/arm/include -Iarch/arm/include/generated -Iinclude \
  -I./arch/arm/include/uapi -Iarch/arm/include/generated/uapi \
  -I./include/uapi -Iinclude/generated/uapi \
  -include ./include/linux/kconfig.h -D__KERNEL__ -mlittle-endian \
  -Wall -Wundef -Wstrict-prototypes -Wno-trigraphs -fno-strict-aliasing \
  -fno-common -Werror-implicit-function-declaration -Wno-format-security \
  -fno-dwarf2-cfi-asm -mabi=aapcs-linux -mno-thumb-interwork -mfpu=vfp \
  -funwind-tables -marm -D__LINUX_ARM_ARCH__=5 -march=armv5te \
  -mtune=arm9tdmi -msoft-float -Uarm -fno-delete-null-pointer-checks \
  -O2 -Wframe-larger-than=1024 -fno-stack-protector \
  -Wno-unused-but-set-variable -fomit-frame-pointer \
  -fno-var-tracking-assignments -Wdeclaration-after-statement \
  -Wno-pointer-sign -fno-strict-overflow -fconserve-stack \
  -Werror=implicit-int -Werror=strict-prototypes -Werror=date-time \
  -DMODULE -fno-pic -DCC_HAVE_ASM_GOTO"

KBSTR='-DKBUILD_STR(s)=#s'

build_mod() {
    local name="$1"; local kbase="$2"; local kmod="$3"; local src="$4"; local dst="$5"
    echo "  -> $src"
    $GCC $BASE "$KBSTR" \
      "-DKBUILD_BASENAME=KBUILD_STR($kbase)" \
      "-DKBUILD_MODNAME=KBUILD_STR($kmod)" \
      -c -o "$dst" "$src" 2>&1 | grep -E 'error:' || true
    if [ ! -s "$dst" ]; then echo "FAIL: $dst empty"; exit 1; fi
}

# ----- HELLO -----
echo "=== [1] Rebuild hello.ko ==="
build_mod hello hello hello drivers/hello/hello.c drivers/hello/hello.o
build_mod hello hello.mod hello drivers/hello/hello.mod.c drivers/hello/hello.mod.o
$LD -EL -r -T ./scripts/module-common.lds --build-id \
  -o drivers/hello/hello.ko \
  drivers/hello/hello.o drivers/hello/hello.mod.o
echo "  $(ls -lh drivers/hello/hello.ko | awk '{print $5, $9}')"

# Verify size
echo "  __this_module size: $(arm-linux-gnueabi-readelf -SW drivers/hello/hello.ko | grep 'gnu.linkonce.this_module' | head -1 | awk '{print $7}')"

# ----- HELLO2 -----
echo "=== [2] Rebuild hello2.ko ==="
build_mod hello2 hello2 hello2 drivers/hello/hello2.c drivers/hello/hello2.o
build_mod hello2 hello2.mod hello2 drivers/hello/hello2.mod.c drivers/hello/hello2.mod.o
$LD -EL -r -T ./scripts/module-common.lds --build-id \
  -o drivers/hello/hello2.ko \
  drivers/hello/hello2.o drivers/hello/hello2.mod.o
echo "  $(ls -lh drivers/hello/hello2.ko | awk '{print $5, $9}')"
echo "  __this_module size: $(arm-linux-gnueabi-readelf -SW drivers/hello/hello2.ko | grep 'gnu.linkonce.this_module' | head -1 | awk '{print $7}')"

# ----- CDC-ACM -----
echo "=== [3] Rebuild cdc-acm.ko ==="
build_mod cdc_acm cdc_acm cdc_acm drivers/usb/class/cdc-acm.c drivers/usb/class/cdc-acm.o
build_mod cdc_acm cdc-acm.mod cdc_acm drivers/usb/class/cdc-acm.mod.c drivers/usb/class/cdc-acm.mod.o
$LD -EL -r -T ./scripts/module-common.lds --build-id \
  -o drivers/usb/class/cdc-acm.ko \
  drivers/usb/class/cdc-acm.o drivers/usb/class/cdc-acm.mod.o
echo "  $(ls -lh drivers/usb/class/cdc-acm.ko | awk '{print $5, $9}')"
echo "  __this_module size: $(arm-linux-gnueabi-readelf -SW drivers/usb/class/cdc-acm.ko | grep 'gnu.linkonce.this_module' | head -1 | awk '{print $7}')"

# ----- USBSERIAL -----
echo "=== [4] Rebuild usbserial.ko (3 sources) ==="
build_mod usb_serial usb_serial usbserial drivers/usb/serial/usb-serial.c drivers/usb/serial/usb-serial.o
build_mod generic generic usbserial drivers/usb/serial/generic.c drivers/usb/serial/generic.o
build_mod bus bus usbserial drivers/usb/serial/bus.c drivers/usb/serial/bus.o
$LD -EL -r -o drivers/usb/serial/usbserial.o \
  drivers/usb/serial/usb-serial.o drivers/usb/serial/generic.o drivers/usb/serial/bus.o
build_mod usbserial usbserial.mod usbserial drivers/usb/serial/usbserial.mod.c drivers/usb/serial/usbserial.mod.o
$LD -EL -r -T ./scripts/module-common.lds --build-id \
  -o drivers/usb/serial/usbserial.ko \
  drivers/usb/serial/usbserial.o drivers/usb/serial/usbserial.mod.o
echo "  $(ls -lh drivers/usb/serial/usbserial.ko | awk '{print $5, $9}')"
echo "  __this_module size: $(arm-linux-gnueabi-readelf -SW drivers/usb/serial/usbserial.ko | grep 'gnu.linkonce.this_module' | head -1 | awk '{print $7}')"

# ----- CH341 -----
echo "=== [5] Rebuild ch341.ko ==="
build_mod ch341 ch341 ch341 drivers/usb/serial/ch341.c drivers/usb/serial/ch341.o
build_mod ch341 ch341.mod ch341 drivers/usb/serial/ch341.mod.c drivers/usb/serial/ch341.mod.o
$LD -EL -r -T ./scripts/module-common.lds --build-id \
  -o drivers/usb/serial/ch341.ko \
  drivers/usb/serial/ch341.o drivers/usb/serial/ch341.mod.o
echo "  $(ls -lh drivers/usb/serial/ch341.ko | awk '{print $5, $9}')"
echo "  __this_module size: $(arm-linux-gnueabi-readelf -SW drivers/usb/serial/ch341.ko | grep 'gnu.linkonce.this_module' | head -1 | awk '{print $7}')"

echo
echo "=== ALLE STØRRELSER MÅ VÆRE 0x158 (344 bytes) ==="
echo "Hvis ja, last opp og test!"
