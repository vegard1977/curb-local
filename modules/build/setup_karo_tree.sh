#!/bin/bash
set -e
cd /home/qfh
mkdir -p curb-build
cd curb-build

echo "=== 1. Klone karo-tx-linux (shallow, bare KARO-TX28-2014-09-10 tag) ==="
if [ ! -d karo-tx-linux ]; then
  git clone --depth 1 --branch KARO-TX28-2014-09-10 \
    https://github.com/karo-electronics/karo-tx-linux.git 2>&1 | tail -5
fi
cd karo-tx-linux
echo "  HEAD: $(git log -1 --oneline)"
echo "  Storrelse: $(du -sh . | cut -f1)"

echo
echo "=== 2. Apply GCC14-kompatibilitetspatcher ==="

# Patch 1: compiler-gcc symlinker (GCC 14 trenger compiler-gcc14.h som peker mot compiler-gcc5.h)
cd include/linux
for n in 5 6 7 8 9 10 11 12 13 14 15; do
  if [ ! -f compiler-gcc${n}.h ]; then
    ln -sf compiler-gcc5.h compiler-gcc${n}.h 2>/dev/null || true
  fi
done
ls -la compiler-gcc*.h | head -5
cd /home/qfh/curb-build/karo-tx-linux

# Patch 2: dtc/yylloc — GCC 14 -fno-common bryter eldre yylloc-deklarasjoner
for f in scripts/dtc/dtc-lexer.lex.c_shipped scripts/dtc/dtc-parser.tab.c_shipped scripts/dtc/dtc-parser.tab.h_shipped; do
  if [ -f "$f" ] && grep -q '^YYLTYPE yylloc' "$f"; then
    sed -i 's/^YYLTYPE yylloc;/extern YYLTYPE yylloc;/' "$f"
    echo "  patchet: $f"
  fi
done

# Patch 3: compiler.h __asmeq — GCC 14 strenge ASM-validering
if grep -q '__asmeq("%0"' arch/arm/include/asm/futex.h 2>/dev/null; then
  echo "  futex.h kan trenge fix (sjekkes senere ved evt build-feil)"
fi

# Patch 4: ARM .S section flags - relevant ved full kjerne-bygg, ikke modul-bygg
echo "  ARM .S patches: kun nodvendig ved full vmlinux-bygg, hopper over"

echo
echo "=== 3. Konfigurer (tx28_defconfig) ==="
make ARCH=arm tx28_defconfig 2>&1 | tail -3

echo
echo "=== 4. Tving riktig vermagic (uten +) ==="
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabi- prepare 2>&1 | tail -3
echo '#define UTS_RELEASE "3.16.0-karo"' > include/generated/utsrelease.h
echo "3.16.0-karo" > include/config/kernel.release
touch .scmversion
cat include/generated/utsrelease.h

echo
echo "=== 5. modules_prepare (genererer Module.symvers stubs) ==="
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabi- modules_prepare 2>&1 | tail -10

echo
echo "=== 6. Bekreft at vi kan bygge cp210x.o ==="
ls -la drivers/usb/serial/cp210x.c
ls -la include/generated/utsrelease.h include/generated/autoconf.h

echo
echo "=== SETUP FERDIG ==="
du -sh /home/qfh/curb-build/karo-tx-linux
