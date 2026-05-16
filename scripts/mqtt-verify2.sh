#!/bin/sh
CFG=/data/mqtt-config.json
# JSON er paa én linje -- bruk lua til aa parse
extract() {
  lua -e "
    local f = io.open('$CFG','r'); local s = f:read('*all'); f:close()
    print((s:match('\"$1\"%s*:%s*\"([^\"]+)\"') or s:match('\"$1\"%s*:%s*([%d.]+)') or ''))
  "
}

MHOST=$(extract broker_host)
MUSER=$(extract username)
MPASS=$(extract password)
echo "Host: $MHOST  Bruker: $MUSER"

echo ""
echo "=== Arduino CT-topics (4 sek) ==="
timeout 4 mosquitto_sub -h "$MHOST" -u "$MUSER" -P "$MPASS" \
  -t 'curb/power/circuit_19' \
  -t 'curb/power/circuit_25' \
  -t 'curb/power/circuit_34' \
  -t 'curb/power/temp/#' \
  -v

echo ""
echo "=== HA discovery for arduino-sensorer (3 sek) ==="
timeout 3 mosquitto_sub -h "$MHOST" -u "$MUSER" -P "$MPASS" \
  -t 'homeassistant/sensor/+/#' \
  -v 2>&1 | grep -E 'circuit_(19|34)|panel_temp|ttyACM0_temp' | head -8
