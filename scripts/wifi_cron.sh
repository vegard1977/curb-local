#!/bin/sh
# WiFi-vakt -- deployes til /etc/wifi_cron.sh, kjores av cron hvert minutt
# (linje i /var/spool/cron/crontabs/root: "* * * * * /etc/wifi_cron.sh").
# Erstatter stock WPS-handler (backup: /etc/wifi_cron.sh.stock-wps.bak).
#
# WiFi-PRIMAER drift med powerline TILSTEDE.
# Powerline (eth1/QCA7000) MAA vaere fysisk tilkoblet -- kreves for at kjernen
# booter (qcaspi pluggable=0; uten powerline henger boot for userspace, og
# WiFi kommer aldri opp -- se kontekst/wifi.md). Vi rorer derfor ALDRI eth1.
# WiFi er primaer datavei (wlan0 metric 1 < eth1 metric 2). Oppgaver:
#  1) wlan0 nede/uten IP -> S51wifi start (recovery for flakete AR9271).
#  2) wlan0 har IP -> gratuitous ARP sa ruteren holder .111 paa WiFi.
#  3) MQTT-helse: broker svarer men ingen ESTABLISHED i 2 min -> restart streamer.
IFACE=wlan0
LOCK=/tmp/wifi_wd.lock
MQF=/tmp/mqtt_fails
DBG=/data/wifi-debug.log
log() { echo "$(date '+%m-%d %H:%M:%S') up=$(cut -d. -f1 /proc/uptime)s [vakt] $*" >> "$DBG"; }
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

HAS_IF=$(/sbin/ip link show $IFACE 2>/dev/null)
HAS_IP=$(/sbin/ip addr show $IFACE 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
if [ -z "$HAS_IF" ] || [ -z "$HAS_IP" ]; then
  log "wlan0 mangler/uten IP -> S51wifi start"
  /etc/init.d/S51wifi start >/dev/null 2>&1
  exit 0
fi

# gratuitous ARP: hold .111 paa WiFi (ikke bundet til kablet powerline-port)
/usr/sbin/arping -U -I $IFACE -c 2 "$HAS_IP" >/dev/null 2>&1

# MQTT-helse (broker fra mqtt-config.json, fallback .49:1883)
BROKER=$(sed -n 's/.*"broker_host"[: ]*"\([0-9.]*\)".*/\1/p' /data/mqtt-config.json 2>/dev/null)
[ -z "$BROKER" ] && BROKER=10.0.0.49
PORT=$(sed -n 's/.*"broker_port"[: ]*\([0-9]*\).*/\1/p' /data/mqtt-config.json 2>/dev/null)
[ -z "$PORT" ] && PORT=1883
if ping -c 1 -W 2 "$BROKER" >/dev/null 2>&1; then
  if netstat -tn 2>/dev/null | grep -q "$BROKER:$PORT.*ESTABLISHED"; then
    rm -f "$MQF"
  else
    m=$(cat "$MQF" 2>/dev/null || echo 0); m=$((m+1)); echo $m > "$MQF"
    if [ $m -ge 2 ]; then
      log "MQTT fast (broker svarer, ingen ESTABLISHED) -> restarter mqtt-streamer"
      P=$(ps | grep '[m]qtt-streamer' | awk '{print $1}'); [ -n "$P" ] && kill $P 2>/dev/null
      rm -f "$MQF"
    fi
  fi
fi
