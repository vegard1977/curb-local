#!/bin/sh
F=/data/lamarr/serial-reader.lua
sed -i 's/\r$//' "$F"
chmod +x "$F"
chown curb:avahi "$F"
lua -e "loadfile('$F')" && echo "Lua OK" || { echo "FEIL syntaks"; exit 1; }

PID=$(ps | grep serial-reader | grep -v grep | awk '{print $1}')
echo "Gammel PID: $PID"
[ -n "$PID" ] && kill "$PID"
sleep 6

echo ""
echo "=== Ny PID ==="
ps | grep serial-reader | grep -v grep

echo ""
echo "=== arduino.json med temp_labels ==="
cat /tmp/www/arduino.json
