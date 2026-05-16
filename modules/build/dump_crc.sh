#!/bin/sh
# Kjøres på Curb — dumper __kcrctab og symboltabell, lagrer til SD-kort

# Finn adressene fra /proc/kallsyms
START=$(grep ' D __start___kcrctab$' /proc/kallsyms | awk '{print "0x"$1}')
STOP=$(grep ' D __stop___kcrctab$' /proc/kallsyms | awk '{print "0x"$1}')
STR_START=$(grep ' R __start___ksymtab_strings$' /proc/kallsyms | awk '{print "0x"$1}')
STR_STOP=$(grep ' R __stop___ksymtab_strings$' /proc/kallsyms | awk '{print "0x"$1}')

echo "__kcrctab:           $START .. $STOP"
echo "__ksymtab_strings:   $STR_START .. $STR_STOP"

# Antall CRC-entries
CNT=$(( ($STOP - $START) / 4 ))
echo "CRC count: $CNT"

# Strings length
STRLEN=$(( $STR_STOP - $STR_START ))
echo "Strings length: $STRLEN"

# Dump CRC-tabell
PHYS_OFFSET=0x80000000
SKIP=$(( ($START - $PHYS_OFFSET) / 4 ))
dd if=/dev/mem bs=4 skip=$SKIP count=$CNT of=/data/sd/kcrctab.bin 2>&1 | tail -1

# Dump string-tabell
SKIP=$(( ($STR_START - $PHYS_OFFSET) ))
dd if=/dev/mem bs=1 skip=$SKIP count=$STRLEN of=/data/sd/ksymtab_strings.bin 2>&1 | tail -1

ls -la /data/sd/kcrctab.bin /data/sd/ksymtab_strings.bin
echo "OK - filer klare på /data/sd/"
