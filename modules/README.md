# Curb Kernel Modules

Custom-bygde Linux 3.16-kjernemoduler for **Curb Energy Monitor** (i.MX28 / ARMv5 / vermagic `3.16.0-karo`).

Bygd manuelt fra Ka-Ro `karo-tx-linux` (tag `KARO-TX28-2014-09-10`) på qfh (Debian 13 / GCC 14.2.0 cross-compile).

> 🏆 Komplett bakgrunn og diagnostikk: se **[../../kontekst/search.md](../../kontekst/search.md)** for hvordan vi løste alle 6 bygg-problemene.

---

## Mappestruktur

```
modules/
├── README.md           ← Denne filen
├── bin/                ← Ferdige .ko-filer (kopier til Curb)
│   ├── cdc-acm.ko      (36 KB) — USB CDC ACM (Arduino Uno/Mega)
│   ├── ch341.ko        (11 KB) — CH340G (klone-brett, billig Arduino Nano)
│   ├── cp210x.ko       (13 KB) — Silicon Labs CP2102 (ESP32 dev-board)
│   ├── hello.ko         (3 KB) — Test-modul med printk
│   ├── hello2.ko        (3 KB) — Minimal test-modul (ingen kjerne-API)
│   ├── usbserial.ko    (45 KB) — Bygd men IKKE brukt (usbserial er builtin på Curb)
│   └── usb-storage-ref.ko (76 KB) — Referansemodul fra Curb (brukt for sammenligning)
├── source/             ← .mod.c-filer (CRC-tabell + module-stub)
│   ├── cdc-acm.mod.c   — 71 symboler
│   ├── ch341.mod.c     — 15 symboler
│   ├── cp210x.mod.c    — 15 symboler
│   ├── hello.mod.c     — 3 symboler
│   ├── hello2.mod.c    — 2 symboler
│   └── crc_database.txt — Sentral CRC-database (oppslag for nye moduler)
├── build/              ← Build-scripts (kjør på qfh)
│   ├── setup_karo_tree.sh        — Initial: klon + apply GCC14-patches
│   ├── fix_compiler_symlinks.sh  — Fix compiler-gccN.h → gcc4.h
│   ├── build_cp210x.sh           — Bygg cp210x.o (sjekk undefined symbols)
│   ├── build_cp210x_full.sh      — Komplett cp210x build (med CRC-er)
│   ├── rebuild_all_v5.sh         — Rebuild cdc-acm/ch341/usbserial med -DCC_HAVE_ASM_GOTO
│   ├── fix_unwind_crc.sh         — Legge til __aeabi_unwind_cpp_pr0 CRC
│   ├── patch_crcs.py             — Python: regex-erstatt CRC-er i .mod.c
│   ├── dump_crc.sh               — Dump hele __kcrctab (Curb-side)
│   ├── lookup_crc.sh             — Per-symbol CRC-oppslag via /proc/kallsyms (Curb-side)
│   ├── install_modules.sh        — Installer cdc-acm + ch341 på Curb
│   └── install_cp210x.sh         — Installer cp210x på Curb (oppdaterer S35cdc-modules)
└── init/
    └── S35cdc-modules            — Init-script (kopieres til /etc/init.d/ på Curb)
```

---

## Installerte moduler på Curb

| Modul | Sti på Curb | Status |
|-------|-------------|--------|
| cdc_acm | `/lib/modules/3.16.0-karo/kernel/drivers/usb/class/cdc-acm.ko` | ✅ Lasta ved boot |
| ch341 | `/lib/modules/3.16.0-karo/kernel/drivers/usb/serial/ch341.ko` | ✅ Lasta ved boot |
| cp210x | `/lib/modules/3.16.0-karo/kernel/drivers/usb/serial/cp210x.ko` | ✅ Lasta ved boot |
| Init-script | `/etc/init.d/S35cdc-modules` | ✅ Kjøres ved boot |

---

## Støttede USB-enheter

| Enhet | Driver | Device-node |
|-------|--------|-------------|
| Arduino Uno (Genuino R3) | cdc_acm | `/dev/ttyACM0` |
| Arduino Mega 2560 | cdc_acm | `/dev/ttyACM0` |
| Arduino Nano (FTDI) | ftdi_sio (**builtin**) | `/dev/ttyUSB0` |
| Arduino Nano (CH340 klone) | ch341 | `/dev/ttyUSB0` |
| ESP32 dev-board (CP2102/CP2104) | cp210x | `/dev/ttyUSB0` |
| ESP32-S2/S3 native USB | cdc_acm | `/dev/ttyACM0` |
| USB-modem (3G/4G stick) | cdc_acm + (option) | `/dev/ttyACM0` |
| Atheros AR9271 WiFi | ath9k_htc (**builtin**) | `wlan0` |

---

## Hvis du må bygge en ny modul

Komplett oppskrift når du har en USB-enhet som Curb ikke gjenkjenner:

### Forutsetning: qfh-byggemiljø klart
- `gcc-arm-linux-gnueabi` installert
- `/home/qfh/curb-build/karo-tx-linux/` klonet (KARO-TX28-2014-09-10 tag)
- `make modules_prepare` kjørt (genererer `include/generated/`)

Hvis ikke: kjør `build/setup_karo_tree.sh` (gjør alt automatisk, ~10 min).

### Bygg-rutine (eksempel: ny driver `foo.ko`)

1. **Compile `foo.o`** for å se hvilke symboler den trenger:
   ```sh
   bash build/build_foo.sh    # Tilpasset versjon av build_cp210x.sh
   # Sjekk listen av "undefined symbols" (U)
   ```

2. **Slå opp CRC-er for de symboler du ikke har i `crc_database.txt`:**
   ```sh
   # Rediger build/lookup_crc.sh — legg til nye symbol-navn
   scp build/lookup_crc.sh root@curb:/data/sd/
   ssh root@curb "sh /data/sd/lookup_crc.sh"
   # Kopier CRC-ene inn i crc_database.txt for fremtidig bruk
   ```

3. **Skriv `foo.mod.c`** basert på cp210x.mod.c-malen, med alle CRC-er.

4. **Bygg og link `foo.ko`:**
   ```bash
   # BASE må inkludere disse 6 KRITISKE flagg:
   #   -fno-pic                — unngå GOT-referanser
   #   -DCC_HAVE_ASM_GOTO      — gir korrekt struct module-størrelse (344 bytes)
   #   -funwind-tables         — standard (trenger CRC for __aeabi_unwind_cpp_pr0)
   #   ARM v5te, ARMv5 vermagic
   # OG: tving vermagic uten "+":
   echo '#define UTS_RELEASE "3.16.0-karo"' > include/generated/utsrelease.h
   ```

5. **Test på Curb:**
   ```sh
   scp foo.ko root@curb:/data/sd/
   ssh root@curb "echo 8 > /proc/sys/kernel/printk; dmesg -c > /dev/null; insmod /data/sd/foo.ko; dmesg | tail"
   ```

6. **Hvis det laster:** kopier til `/lib/modules/.../` og legg til i `/etc/init.d/S35cdc-modules`.

---

## Manuell lasting / unloading

```sh
# Last alle (allerede ved boot via S35cdc-modules)
/etc/init.d/S35cdc-modules start

# Stopp alle
/etc/init.d/S35cdc-modules stop

# Enkelt-modul
/sbin/insmod /lib/modules/3.16.0-karo/kernel/drivers/usb/serial/cp210x.ko
/sbin/rmmod cp210x

# Verifiser
/sbin/lsmod | grep -E 'cdc|ch341|cp210x'
ls /dev/ttyACM* /dev/ttyUSB*
```

---

## Deploy fra denne mappen til Curb

```powershell
# Fra Windows (PuTTY/plink):
$KEY = "$env:USERPROFILE\.ssh\id_rsa_curb.ppk"
$CURB = "root@10.0.0.107"

# Last opp .ko-filene
foreach ($ko in @('cdc-acm', 'ch341', 'cp210x')) {
  pscp -scp -i $KEY -batch "bin/$ko.ko" "${CURB}:/data/sd/$ko.ko"
}

# Installer permanent + oppdater init-script
pscp -scp -i $KEY -batch "build/install_cp210x.sh" "${CURB}:/data/sd/"
plink -ssh -i $KEY -batch $CURB "sh /data/sd/install_cp210x.sh"
```

---

## Lærdom — de 6 kritiske byggfix-ene

| # | Problem | Fix |
|---|---------|-----|
| 1 | `module_layout` CRC mismatch | Bruk Curbs CRC `0x68ee78b9`, ikke vår mainline-build |
| 2 | Funksjons-CRC-er ulike mellom builds | Patche `*.mod.c` med Curbs `__kcrctab`-verdier (`lookup_crc.sh`) |
| 3 | GCC 14 lager GOT-referanser | `-fno-pic` i compile-flagg |
| 4 | `struct module` 8 bytes for liten | `-DCC_HAVE_ASM_GOTO` for å aktivere `HAVE_JUMP_LABEL` |
| 5 | Vermagic-streng hadde `+` (dirty tree) | `echo '#define UTS_RELEASE "3.16.0-karo"' > include/generated/utsrelease.h` |
| 6 | Manglet CRC for `__aeabi_unwind_cpp_pr0` | Legg til `{ 0xefd6cf06, ... }` i alle `*.mod.c` |

> Bonus: `usbserial.ko` trenger vi IKKE bygge — `CONFIG_USB_SERIAL=y` på Curb (builtin).

---

## Build-miljø

- **Host:** qfh (RPi, `10.0.0.105`) — Debian 13, kjerne 6.12, `arm-linux-gnueabi-gcc 14.2.0`
- **Target:** Curb Energy Monitor (`10.0.0.107`) — Freescale i.MX28, ARMv5TE, 64 MB RAM
- **Source:** GitHub `karo-electronics/karo-tx-linux` tag `KARO-TX28-2014-09-10`
- **Toolchain:** `gcc-arm-linux-gnueabi` (apt-pakke, Debian)

---

## SSH-nøkler

- **qfh:** `~/.ssh/id_ed25519.ppk`
- **Curb:** `~/.ssh/id_rsa_curb.ppk` (krever `-scp` for pscp — dropbear mangler sftp)
