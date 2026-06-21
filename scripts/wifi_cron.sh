#!/bin/sh
# WiFi-vakt -- deployes til /etc/wifi_cron.sh, kjores av cron hvert minutt.
# WiFi-only drift (powerline IKKE tilkoblet).
#  1) eth1 (powerline) dod -> flush (2 paaf. gateway-feil via eth1).
#  2) wlan0 mangler/uten IP -> S51wifi start.
#  3) wlan0 har IP men naar IKKE gateway (thrashing mellom flere IOT-AP / stuck
#     wpa) -> S51wifi start (ren enkelt wpa). 2 paaf. feil for vi handler.
#  4) wlan0 OK -> gratuitous ARP (ruteren laerer .111 paa WiFi).
#  5) MQTT-helse: broker svarer men ingen ESTABLISHED -> restart streamer.
IFACE=wlan0
GW=10.0.0.138
LOCK=/tmp/wifi_wd.lock
FAILF=/tmp/eth1_gw_fails
WFAIL=/tmp/wlan_gw_fails
MQF=/tmp/mqtt_fails
DBG=/data/wifi-debug.log
log() { echo "$(date '+%m-%d %H:%M:%S') up=$(cut -d. -f1 /proc/uptime)s [vakt] $*" >> "$DBG"; }
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# 1) dod powerline?
ETH_IP=$(/sbin/ip addr show eth1 2>/dev/null | grep 'inet ')
if [ -n "$ETH_IP" ]; then
  if ping -c 2 -W 2 -I eth1 $GW >/dev/null 2>&1; then rm -f "$FAILF"
  else
    n=$(cat "$FAILF" 2>/dev/null||echo 0); n=$((n+1)); echo $n > "$FAILF"
    if [ $n -ge 2 ]; then
      log "eth1 dod -> flush"; /sbin/ip addr flush dev eth1 2>/dev/null; /sbin/ip link set eth1 down 2>/dev/null; rm -f "$FAILF"
    fi
  fi
fi

HAS_IF=$(/sbin/ip link show $IFACE 2>/dev/null)
HAS_IP=$(/sbin/ip addr show $IFACE 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
if [ -z "$HAS_IF" ] || [ -z "$HAS_IP" ]; then
  log "wlan0 mangler/uten IP -> S51wifi start"; /etc/init.d/S51wifi start >/dev/null 2>&1; exit 0
fi

# 3) har IP men naar gateway? (fanger thrashing/stuck wpa)
if ping -c 2 -W 2 -I $IFACE $GW >/dev/null 2>&1; then
  rm -f "$WFAIL"
else
  w=$(cat "$WFAIL" 2>/dev/null||echo 0); w=$((w+1)); echo $w > "$WFAIL"
  if [ $w -ge 2 ]; then
    log "wlan0 har IP men naar ikke gateway (thrashing) -> S51wifi start"; /etc/init.d/S51wifi start >/dev/null 2>&1; rm -f "$WFAIL"; exit 0
  fi
fi

# 4) gratuitous ARP
/usr/sbin/arping -U -I $IFACE -c 2 "$HAS_IP" >/dev/null 2>&1

# 5) MQTT-helse
BROKER=$(sed -n 's/.*"broker_host"[: ]*"\([0-9.]*\)".*/\1/p' /data/mqtt-config.json 2>/dev/null)
[ -z "$BROKER" ] && BROKER=10.0.0.49
PORT=$(sed -n 's/.*"broker_port"[: ]*\([0-9]*\).*/\1/p' /data/mqtt-config.json 2>/dev/null)
[ -z "$PORT" ] && PORT=1883
if ping -c 1 -W 2 "$BROKER" >/dev/null 2>&1; then
  if netstat -tn 2>/dev/null | grep -q "$BROKER:$PORT.*ESTABLISHED"; then rm -f "$MQF"
  else
    m=$(cat "$MQF" 2>/dev/null||echo 0); m=$((m+1)); echo $m > "$MQF"
    if [ $m -ge 2 ]; then
      log "MQTT fast -> restart streamer"; P=$(ps|grep "[m]qtt-streamer"|awk "{print \$1}"); [ -n "$P" ] && kill $P 2>/dev/null; rm -f "$MQF"
    fi
  fi
fi
