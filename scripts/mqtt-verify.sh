#!/bin/sh
MUSER=$(grep username /data/mqtt-config.json | sed 's/.*: *"//;s/".*//')
MPASS=$(grep password /data/mqtt-config.json | sed 's/.*: *"//;s/".*//')
MHOST=$(grep broker_host /data/mqtt-config.json | sed 's/.*: *"//;s/".*//')
echo "Bruker: $MUSER -> $MHOST"

echo ""
echo "=== Arduino MQTT-topics (5 sek) ==="
timeout 5 mosquitto_sub -h "$MHOST" -u "$MUSER" -P "$MPASS" \
  -t 'curb/power/circuit_19' \
  -t 'curb/power/circuit_25' \
  -t 'curb/power/circuit_34' \
  -t 'curb/power/temp/#' \
  -v

echo ""
echo "=== HA discovery for Arduino-sensorer ==="
timeout 3 mosquitto_sub -h "$MHOST" -u "$MUSER" -P "$MPASS" \
  -t 'homeassistant/sensor/+/+_circuit_19_a/config' \
  -t 'homeassistant/sensor/+/+_circuit_34_a/config' \
  -t 'homeassistant/sensor/+/+panel_temp_+/config' \
  -t 'homeassistant/sensor/+/+ttyACM0_temp_+/config' \
  -v 2>&1 | head -40
