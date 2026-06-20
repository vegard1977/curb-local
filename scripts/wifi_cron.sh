#!/bin/sh
# WiFi-vakt -- deployes til /etc/wifi_cron.sh, kjores av cron hvert minutt
# (linje i /var/spool/cron/crontabs/root: "* * * * * /etc/wifi_cron.sh").
# Erstatter stock WPS-handler (backup: /etc/wifi_cron.sh.stock-wps.bak) som
# ikke virker med var ctrl-lose wpa_supplicant.
#
# Sikrer palitelig WiFi-only-drift UTEN a sette powerline-reserven i fare:
#  1) Powerline dod? eth1 carrier LYVER (Curb<->QCA7000-link star selv om
#     powerline-nettet er borte), sa vi pinger gateway via eth1. KREVER 2
#     paafolgende feil (~2 min) for vi rorer eth1 -- en frisk powerline feiler
#     aldri, en blip ved boot rives ALDRI ned. Forst da ryddes eth1 (ellers
#     gar broker-trafikk ut den dode porten og MQTT stopper).
#  2) Mangler wlan0/IP -> S51wifi start (recovery for flakete AR9271).
#  3) wlan0 har IP -> gratuitous ARP sa ruteren vet IP-en er pa WiFi (ellers
#     holder den den bundet til den kablede powerline-porten -> WiFi-only
#     unabar nar kabelen trekkes).
IFACE=wlan0
GW=10.0.0.138
LOCK=/tmp/wifi_wd.lock
FAILF=/tmp/eth1_gw_fails
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

ETH_IP=$(/sbin/ip addr show eth1 2>/dev/null | grep 'inet ')
if [ -n "$ETH_IP" ]; then
  if ping -c 2 -W 2 -I eth1 $GW >/dev/null 2>&1; then
    rm -f "$FAILF"                         # frisk powerline -> nullstill teller
  else
    n=$(cat "$FAILF" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$FAILF"
    if [ $n -ge 2 ]; then                  # 2 paafolgende min -> powerline dod
      logger "wifi-vakt: eth1 naadde ikke gateway ${n}x -- rydder eth1 (WiFi-only)"
      /sbin/ip addr flush dev eth1 2>/dev/null
      /sbin/ip link set eth1 down 2>/dev/null
      rm -f "$FAILF"
    fi
  fi
fi

HAS_IF=$(/sbin/ip link show $IFACE 2>/dev/null)
HAS_IP=$(/sbin/ip addr show $IFACE 2>/dev/null | grep 'inet ')
if [ -z "$HAS_IF" ] || [ -z "$HAS_IP" ]; then
  logger "wifi-vakt: $IFACE mangler grensesnitt/IP -- kjorer S51wifi start"
  /etc/init.d/S51wifi start >/dev/null 2>&1
else
  WIP=$(echo "$HAS_IP" | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
  [ -n "$WIP" ] && /usr/sbin/arping -U -I $IFACE -c 2 "$WIP" >/dev/null 2>&1
fi
