#!/bin/bash
set -e
cd /home/qfh/curb-build/karo-tx-linux

CD=/home/qfh/curb-build/karo-tx-linux

echo "=== Sjekk eksisterende __aeabi_unwind_cpp_pr0 CRC i alle .mod.c ==="
for f in drivers/hello/hello.mod.c drivers/hello/hello2.mod.c drivers/usb/class/cdc-acm.mod.c drivers/usb/serial/ch341.mod.c drivers/usb/serial/usbserial.mod.c; do
  echo "--- $f ---"
  grep -E '__aeabi_unwind_cpp_pr0' "$f" || echo "(missing)"
done

echo
echo "=== Oppdater hello2.mod.c (legg til __aeabi_unwind_cpp_pr0 CRC) ==="
cat > drivers/hello/hello2.mod.c << 'EOF'
#include <linux/module.h>
#include <linux/vermagic.h>
#include <linux/compiler.h>

MODULE_INFO(vermagic, VERMAGIC_STRING);

struct module __this_module
__attribute__((section(".gnu.linkonce.this_module"))) = {
	.name = KBUILD_MODNAME,
	.init = init_module,
#ifdef CONFIG_MODULE_UNLOAD
	.exit = cleanup_module,
#endif
	.arch = MODULE_ARCH_INIT,
};

static const struct modversion_info ____versions[]
__used
__attribute__((section("__versions"))) = {
	{ 0x68ee78b9, __VMLINUX_SYMBOL_STR(module_layout) },
	{ 0xefd6cf06, __VMLINUX_SYMBOL_STR(__aeabi_unwind_cpp_pr0) },
};

static const char __module_depends[]
__used
__attribute__((section(".modinfo"))) =
"depends=";
EOF

echo "=== Fiks __aeabi_unwind_cpp_pr0 CRC i alle .mod.c som har feil verdi ==="
for f in drivers/usb/class/cdc-acm.mod.c drivers/usb/serial/ch341.mod.c drivers/usb/serial/usbserial.mod.c; do
  if grep -q '__aeabi_unwind_cpp_pr0' "$f"; then
    # Bytt ut hvilken som helst CRC for __aeabi_unwind_cpp_pr0 med 0xefd6cf06
    sed -i 's/{ 0x[0-9a-f]\+, __VMLINUX_SYMBOL_STR(__aeabi_unwind_cpp_pr0) }/{ 0xefd6cf06, __VMLINUX_SYMBOL_STR(__aeabi_unwind_cpp_pr0) }/' "$f"
    echo "  $f: oppdatert"
    grep '__aeabi_unwind_cpp_pr0' "$f"
  else
    echo "  $f: MANGLER __aeabi_unwind_cpp_pr0 — legger til"
    # Sett inn etter siste { ... } før den lukkende };
    sed -i '/^static const struct modversion_info ____versions/,/^};/{
      s/^};$/\t{ 0xefd6cf06, __VMLINUX_SYMBOL_STR(__aeabi_unwind_cpp_pr0) },\n};/
    }' "$f"
    grep '__aeabi_unwind_cpp_pr0' "$f"
  fi
done

echo
echo "=== Rebuild alle med fikset CRC ==="

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

rebuild_mod() {
    local kbase="$1"; local kmod="$2"; local src="$3"; local dst="$4"
    $GCC $BASE "$KBSTR" \
      "-DKBUILD_BASENAME=KBUILD_STR($kbase)" \
      "-DKBUILD_MODNAME=KBUILD_STR($kmod)" \
      -c -o "$dst" "$src" 2>&1 | grep -E 'error:' | head -3 || true
    [ -s "$dst" ] || { echo "FAIL: $dst"; exit 1; }
}

# hello2
rebuild_mod hello2.mod hello2 drivers/hello/hello2.mod.c drivers/hello/hello2.mod.o
$LD -EL -r -T ./scripts/module-common.lds --build-id \
  -o drivers/hello/hello2.ko \
  drivers/hello/hello2.o drivers/hello/hello2.mod.o
echo "  hello2.ko: $(ls -l drivers/hello/hello2.ko | awk '{print $5}')"

# cdc-acm
rebuild_mod cdc-acm.mod cdc_acm drivers/usb/class/cdc-acm.mod.c drivers/usb/class/cdc-acm.mod.o
$LD -EL -r -T ./scripts/module-common.lds --build-id \
  -o drivers/usb/class/cdc-acm.ko \
  drivers/usb/class/cdc-acm.o drivers/usb/class/cdc-acm.mod.o

# usbserial
rebuild_mod usbserial.mod usbserial drivers/usb/serial/usbserial.mod.c drivers/usb/serial/usbserial.mod.o
$LD -EL -r -T ./scripts/module-common.lds --build-id \
  -o drivers/usb/serial/usbserial.ko \
  drivers/usb/serial/usbserial.o drivers/usb/serial/usbserial.mod.o

# ch341
rebuild_mod ch341.mod ch341 drivers/usb/serial/ch341.mod.c drivers/usb/serial/ch341.mod.o
$LD -EL -r -T ./scripts/module-common.lds --build-id \
  -o drivers/usb/serial/ch341.ko \
  drivers/usb/serial/ch341.o drivers/usb/serial/ch341.mod.o

echo
echo "=== Verifiser CRC i .ko-filene (binærdump av __versions) ==="
for f in drivers/hello/hello2.ko drivers/hello/hello.ko drivers/usb/class/cdc-acm.ko drivers/usb/serial/usbserial.ko drivers/usb/serial/ch341.ko; do
  echo "--- $f ---"
  arm-linux-gnueabi-objdump -s -j __versions "$f" | grep -A1 unwind || true
done
