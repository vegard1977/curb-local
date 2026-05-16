#!/bin/sh
HM_PID=$(ps | grep '/usr/bin/hm' | grep -v grep | awk '{print $1}')
echo "HM PID: $HM_PID"
if [ -z "$HM_PID" ]; then
  echo "FEIL: fant ikke hm-prosess"
  exit 1
fi
kill -HUP "$HM_PID"
sleep 5
echo ""
echo "=== Prosesser etter SIGHUP ==="
ps | grep -E 'serial-reader|mqtt-streamer|api-server|sampler|hm ' | grep -v grep

echo ""
echo "=== hm-logg siste 20 linjer ==="
tail -20 /var/log/messages 2>/dev/null | grep -i hm | tail -10

echo ""
echo "=== serial-reader logg ==="
tail -15 /var/log/serial-reader.log 2>/dev/null
