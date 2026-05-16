#!/bin/sh
# Slå opp CRC for et liste av symboler ved å bruke /proc/kallsyms + /dev/mem
# Kjøres på Curb

# Konstanter (verifisert fra kallsyms)
START_KSYM=0xc06e3858     # __start___ksymtab
START_CRC=0xc06efcf0      # __start___kcrctab
PHYS_OFFSET=0x80000000    # virt - phys

SYMBOLS="
__aeabi_unwind_cpp_pr0
dev_err
dev_warn
kfree
__kmalloc
kmalloc_caches
kmem_cache_alloc
tty_encode_baud_rate
usb_control_msg
usb_reset_device
usb_serial_deregister_drivers
usb_serial_generic_close
usb_serial_generic_open
usb_serial_register_drivers
module_layout
"

echo "# CRC-lookup for cp210x-symboler"
echo "# Genererert: $(date)"
echo

for sym in $SYMBOLS; do
  # Finn __ksymtab_<sym> adresse
  KSYM_ADDR=$(grep " R __ksymtab_${sym}\$" /proc/kallsyms | awk '{print "0x"$1}')
  if [ -z "$KSYM_ADDR" ]; then
    echo "MANGLER: $sym (ikke i __ksymtab)"
    continue
  fi

  # Beregn index (hver entry er 8 bytes)
  INDEX=$(( ($KSYM_ADDR - $START_KSYM) / 8 ))

  # CRC ligger ved __kcrctab + index*4
  CRC_ADDR=$(( $START_CRC + $INDEX * 4 ))
  CRC_OFFSET=$(( $CRC_ADDR - $PHYS_OFFSET ))

  # Les 4 bytes fra /dev/mem
  CRC=$(dd if=/dev/mem bs=4 count=1 skip=$(( $CRC_OFFSET / 4 )) 2>/dev/null | od -An -t x4 | tr -d ' ')
  printf "0x%s  %s\n" "$CRC" "$sym"
done
