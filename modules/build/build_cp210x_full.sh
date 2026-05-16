#!/bin/bash
set -e
cd /home/qfh/curb-build/karo-tx-linux

# Bekreft vermagic
echo '#define UTS_RELEASE "3.16.0-karo"' > include/generated/utsrelease.h
echo "3.16.0-karo" > include/config/kernel.release

# Skriv cp210x.mod.c med korrekte CRC-er
cat > drivers/usb/serial/cp210x.mod.c << 'EOF'
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
	{ 0xb8dd67c5, __VMLINUX_SYMBOL_STR(usb_serial_deregister_drivers) },
	{ 0x8e0ae475, __VMLINUX_SYMBOL_STR(usb_serial_register_drivers) },
	{ 0x460e606f, __VMLINUX_SYMBOL_STR(usb_serial_generic_open) },
	{ 0x751bb41f, __VMLINUX_SYMBOL_STR(usb_serial_generic_close) },
	{ 0x468ee2a8, __VMLINUX_SYMBOL_STR(tty_encode_baud_rate) },
	{ 0x1c89523a, __VMLINUX_SYMBOL_STR(usb_reset_device) },
	{ 0xe36d8f83, __VMLINUX_SYMBOL_STR(usb_control_msg) },
	{ 0x12da5bb2, __VMLINUX_SYMBOL_STR(__kmalloc) },
	{ 0x9ac1ca58, __VMLINUX_SYMBOL_STR(kmem_cache_alloc) },
	{ 0x5aef5059, __VMLINUX_SYMBOL_STR(kmalloc_caches) },
	{ 0x037a0cba, __VMLINUX_SYMBOL_STR(kfree) },
	{ 0x1a2bfe0c, __VMLINUX_SYMBOL_STR(dev_err) },
	{ 0x0116bd00, __VMLINUX_SYMBOL_STR(dev_warn) },
	{ 0xefd6cf06, __VMLINUX_SYMBOL_STR(__aeabi_unwind_cpp_pr0) },
};

static const char __module_depends[]
__used
__attribute__((section(".modinfo"))) =
"depends=";
EOF

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

echo "=== Compile cp210x.mod.c ==="
$GCC $BASE "$KBSTR" \
  '-DKBUILD_BASENAME=KBUILD_STR(cp210x.mod)' \
  '-DKBUILD_MODNAME=KBUILD_STR(cp210x)' \
  -c -o drivers/usb/serial/cp210x.mod.o \
  drivers/usb/serial/cp210x.mod.c 2>&1 | grep -E 'error:' | head -10 || echo "  no errors"

echo
echo "=== Link cp210x.ko ==="
$LD -EL -r -T ./scripts/module-common.lds --build-id \
  -o drivers/usb/serial/cp210x.ko \
  drivers/usb/serial/cp210x.o \
  drivers/usb/serial/cp210x.mod.o

echo
echo "=== Verifikasjon ==="
ls -lh drivers/usb/serial/cp210x.ko
echo "--- vermagic ---"
strings drivers/usb/serial/cp210x.ko | grep vermagic
echo "--- __this_module size (skal være 158 hex = 344 dec) ---"
arm-linux-gnueabi-readelf -SW drivers/usb/serial/cp210x.ko | grep gnu.linkonce | awk '{print "size:",$7}'
echo "--- GOT-sjekk ---"
$NM drivers/usb/serial/cp210x.ko | grep GLOBAL_OFFSET && echo "WARN" || echo "GOT: clean"
echo "--- Undefined (skal være kun de vi kjenner) ---"
$NM drivers/usb/serial/cp210x.ko | grep '^         U ' | awk '{print "  "$2}'
