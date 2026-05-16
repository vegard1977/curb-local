#!/bin/bash
set -e
cd /home/qfh/curb-build/karo-tx-linux

# Bekreft utsrelease (kan ha blitt re-generert av make)
echo '#define UTS_RELEASE "3.16.0-karo"' > include/generated/utsrelease.h
echo "3.16.0-karo" > include/config/kernel.release

GCC=arm-linux-gnueabi-gcc
LD=arm-linux-gnueabi-ld
NM=arm-linux-gnueabi-nm

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

echo "=== Compile cp210x.c ==="
$GCC $BASE "$KBSTR" \
  '-DKBUILD_BASENAME=KBUILD_STR(cp210x)' \
  '-DKBUILD_MODNAME=KBUILD_STR(cp210x)' \
  -c -o drivers/usb/serial/cp210x.o \
  drivers/usb/serial/cp210x.c 2>&1 | grep -E 'error:' | head -10 || echo "  no errors"

ls -lh drivers/usb/serial/cp210x.o
echo
echo "=== GOT-sjekk ==="
$NM drivers/usb/serial/cp210x.o | grep GLOBAL_OFFSET && echo "WARN: GOT present" || echo "GOT: clean"

echo
echo "=== Undefined symbols (det vi trenger CRC for) ==="
$NM drivers/usb/serial/cp210x.o | grep '^         U ' | awk '{print $2}' | sort -u | tee /tmp/cp210x_symbols.txt
echo
echo "Antall undefined: $(wc -l < /tmp/cp210x_symbols.txt)"
