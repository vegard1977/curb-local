#!/bin/sh
# curb_status.sh -- kjoeres ved boot av hm (health monitor)
# Kopierer webgrensesnitt til /tmp/www/ og lager redirect fra rot-URL.
#
# Originale PLC/ping/log-kall er fjernet -- disse var trege og unodvendige.
# All systeminformasjon er tilgjengelig via /tmp/www/sysinfo.json
# (skrevet hvert 10s av mqtt-streamer.lua).

BASE_DIR="/tmp/www"
mkdir -p "$BASE_DIR"

# ── Rot-URL: redirect til energy-dashboard ────────────────────────────────────
cat > "$BASE_DIR/index.html" << 'EOF'
<!DOCTYPE html>
<html><head><meta charset="UTF-8">
<meta http-equiv="refresh" content="0;url=energy.html">
<title>Curb Energy</title>
</head><body>
<a href="energy.html">&#9889; Curb Energy Dashboard</a>
</body></html>
EOF

# ── Symlink webgrensesnitt fra persistent lagring til RAM-webroot ──────────────
# /tmp er i RAM, derfor symlinker (ikke cp): endringer i /data/sd/www reflekteres
# umiddelbart i /tmp/www uten å kjøre dette skriptet på nytt. Symlinkene gjenskapes
# ved boot. lighttpd har server.follow-symlink = "enable" satt.
for PAGE in energy stats settings calibration sysinfo serial-guide usb kursliste wifi arduino modules cli; do
  SRC="/data/sd/www/${PAGE}.html"
  DST="$BASE_DIR/${PAGE}.html"
  [ -f "$SRC" ] && ln -sf "$SRC" "$DST"
done

# ── Symlink bilder ────────────────────────────────────────────────────────────
for IMG in /data/sd/www/*.jpg /data/sd/www/*.jpeg /data/sd/www/*.png /data/sd/www/*.gif; do
  [ -f "$IMG" ] && ln -sf "$IMG" "$BASE_DIR/$(basename "$IMG")"
done
true   # hindrer at tomt glob gir exit 1 i busybox
