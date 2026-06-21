#!/bin/sh
# WiFi-vakt -- deployes til /etc/wifi_cron.sh, kjores av cron hvert minutt.
# WiFi-only drift (powerline IKKE tilkoblet). Curb booter stickless uten
# powerline; WiFi-sticken settes inn etter boot (AR9271 feiler hvis den er i
# under boot -- se kontekst/wifi.md).
#  1) eth1 (powerline) dod? Carrier LYVER, sa ping gateway via eth1. 2 paaf.
#     feil -> flush eth1 (ellers forgifter den dode .107-ruten utgaaende trafikk).
#  2) wlan0 nede/uten IP -> S51wifi start.
#  3) wlan0 har IP -> gratuitous ARP (ruteren laerer .111 paa WiFi).
#  4) MQTT-helse: broker svarer men ingen ESTABLISHED i 2 min -> restart streamer.
IFACE=wlan0
GW=10.0.0.138
LOCK=/tmp/wifi_wd.lock
FAILF=/tmp/eth1_gw_fails
MQF=/tmp/mqtt_fails
DBG=/data/wifi-debug.log
log() { echo "$(date '+%m-%d %H:%M:%S') up=$(cut -d. -f1 /proc/uptime)s [vakt] $*" >> "$DBG"; }
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

ETH_IP=$(/sbin/ip addr show eth1 2>/dev/null | grep 'inet ')
if [ -n "$ETH_IP" ]; then
  if ping -c 2 -W 2 -I eth1 $GW >/dev/null 2>&1; then
    rm -f "$FAILF"
  else
    n=$(cat "$FAILF" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$FAILF"
    if [ $n -ge 2 ]; then
      log "eth1 naar ikke gateway (powerline dod) -> flush eth1"
      /sbin/ip addr flush dev eth1 2>/dev/null
      /sbin/ip link set eth1 down 2>/dev/null
      rm -f "$FAILF"
    fi
  fi
fi

HAS_IF=$(/sbin/ip link show $IFACE 2>/dev/null)
HAS_IP=$(/sbin/ip addr show $IFACE 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
if [ -z "$HAS_IF" ] || [ -z "$HAS_IP" ]; then
  log "wlan0 mangler/uten IP -> S51wifi start"
  /etc/init.d/S51wifi start >/dev/null 2>&1
  exit 0
fi

/usr/sbin/arping -U -I $IFACE -c 2 "$HAS_IP" >/dev/null 2>&1

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
      log "MQTT fast -> restart streamer"
      P=$(ps | grep '[m]qtt-streamer' | awk '{print $1}'); [ -n "$P" ] && kill $P 2>/dev/null
      rm -f "$MQF"
    fi
  fi
fi
