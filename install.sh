#!/usr/bin/env bash
# =============================================================================
# install.sh -- Curb Energy Monitor :: Local web-interface installer
# =============================================================================
# Usage:
#   bash install.sh              # Prompts for IP and password interactively
#   bash install.sh 10.0.0.107   # IP as argument, password prompted
#
# Requirements: bash + ssh  (Git Bash on Windows, terminal on Mac/Linux)
# =============================================================================

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "\n  ${RED}[ERROR]${NC} $*" >&2; exit 1; }
step() { echo -e "\n${CYAN}${BOLD}==> $*${NC}"; }
info() { echo -e "        $*"; }
dbg()  { echo -e "  ${CYAN}[DBG]${NC}   $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Log file ──────────────────────────────────────────────────────────────────
LOG_FILE="$SCRIPT_DIR/install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "install.sh started $(date)"
echo "Log: $LOG_FILE"

# ── Error handling ────────────────────────────────────────────────────────────
trap 'echo -e "\n${RED}[ERROR]${NC} Command failed on line $LINENO: ${YELLOW}${BASH_COMMAND}${NC}" >&2
      echo "  Full log: $LOG_FILE"' ERR
set -euo pipefail

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Curb Energy Monitor -- Installer               ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""

# ── IP address ────────────────────────────────────────────────────────────────
if [ -n "${1:-}" ]; then
  CURB_IP="$1"
  echo -e "  IP address: ${CYAN}$CURB_IP${NC} (from argument)"
else
  read -p "  Curb IP address [10.0.0.107]: " CURB_IP
  CURB_IP="${CURB_IP:-10.0.0.107}"
fi
echo ""

# ── SSH setup ─────────────────────────────────────────────────────────────────
# Use sshpass if available (one password prompt) -- falls back to plain ssh (many prompts)
step "SSH authentication..."

# Curb kjoerer gammel Dropbear som kun stoetter rsa/dss.
# PubkeyAcceptedAlgorithms=+ssh-rsa trengs fordi moderne OpenSSH
# tilbyr rsa-sha2-256/512 som Dropbear ikke forstaar.
CURB_KEY="${CURB_KEY:-$HOME/.ssh/id_rsa_curb}"

SSH_BASE="ssh \
  -i $CURB_KEY \
  -o PubkeyAcceptedAlgorithms=+ssh-rsa \
  -o ConnectTimeout=10 \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=3 \
  -o StrictHostKeyChecking=accept-new \
  -o PasswordAuthentication=no \
  -o BatchMode=yes \
  -o LogLevel=ERROR"

SSH="$SSH_BASE"

if [ ! -f "$CURB_KEY" ]; then
  err "SSH-nøkkel ikke funnet: $CURB_KEY
        Generer med: ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa_curb -N ''
        Installer med: ssh-copy-id -i ~/.ssh/id_rsa_curb.pub root@$CURB_IP"
fi
ok "Bruker SSH-nøkkel: $CURB_KEY"

step "Testing connection to root@$CURB_IP..."
if ! $SSH root@"$CURB_IP" "echo ok" 2>/dev/null; then
  err "Tilkobling til root@$CURB_IP feilet.
        Sjekk:
          1. Riktig IP-adresse (ping $CURB_IP)
          2. Curb er på nettverket
          3. Nøkkel installert på Curb: ssh-copy-id -i $CURB_KEY.pub root@$CURB_IP"
fi
ok "Koblet til $CURB_IP"

# ── Helper functions ──────────────────────────────────────────────────────────
# remote_timeout: wrapper med 60s maks for kommandoer som kan henge
# (f.eks. filoperasjoner på UBIFS under stress)
remote() {
  dbg "remote: $*"
  timeout 60 $SSH root@"$CURB_IP" "$@"
  local rc=$?
  [ $rc -eq 124 ] && echo -e "  ${RED}[TIMEOUT]${NC} Kommando hang i 60s: $*" >&2
  [ $rc -ne 0 ] && echo -e "  ${RED}[!]${NC} remote feilet (exit $rc): $*" >&2
  return $rc
}

upload() {
  local src="$1" dst="$2"
  dbg "upload: $src -> $dst"
  timeout 30 $SSH root@"$CURB_IP" "cat > $dst" < "$src" \
    || err "Upload feilet: $(basename "$src") -> $dst"
  ok "$(basename "$src") -> $dst"
}

# ── Check local files ─────────────────────────────────────────────────────────
step "Checking local files..."
MISSING=0
for f in \
    "$SCRIPT_DIR/mqtt-streamer.lua" \
    "$SCRIPT_DIR/api-server.lua" \
    "$SCRIPT_DIR/calibration.json" \
    "$SCRIPT_DIR/webserver/energy.html" \
    "$SCRIPT_DIR/webserver/settings.html" \
    "$SCRIPT_DIR/webserver/calibration.html" \
    "$SCRIPT_DIR/webserver/sysinfo.html" \
    "$SCRIPT_DIR/webserver/serial-guide.html" \
    "$SCRIPT_DIR/webserver/stats.html"; do
  if [ -f "$f" ]; then
    ok "$(basename "$f")"
  else
    warn "Missing: $f"
    MISSING=$((MISSING + 1))
  fi
done
[ $MISSING -gt 0 ] && err "$MISSING file(s) missing. Run the script from the project root (where install.sh lives)."

# ── Backup ────────────────────────────────────────────────────────────────────
step "Creating backup on Curb device..."
BACKUP_DIR="/data/backup-$(date +%Y%m%d-%H%M%S)"
remote "
  mkdir -p $BACKUP_DIR
  [ -f /etc/hm.conf ]                   && cp /etc/hm.conf                   $BACKUP_DIR/ && echo '  hm.conf'
  [ -f /usr/local/bin/curb_status.sh ]  && cp /usr/local/bin/curb_status.sh  $BACKUP_DIR/ && echo '  curb_status.sh'
  [ -f /data/lamarr/mqtt-streamer.lua ] && cp /data/lamarr/mqtt-streamer.lua $BACKUP_DIR/ && echo '  mqtt-streamer.lua'
  [ -f /data/lamarr/api-server.lua ]    && cp /data/lamarr/api-server.lua    $BACKUP_DIR/ && echo '  api-server.lua'
  [ -f /data/calibration.json ]         && cp /data/calibration.json         $BACKUP_DIR/ && echo '  calibration.json'
  [ -f /data/mqtt-config.json ]         && cp /data/mqtt-config.json         $BACKUP_DIR/ && echo '  mqtt-config.json'
"
ok "Backup saved to $BACKUP_DIR"

# ── Lua scripts ───────────────────────────────────────────────────────────────
step "Uploading Lua scripts..."
remote "mkdir -p /data/lamarr"
upload "$SCRIPT_DIR/mqtt-streamer.lua" "/data/lamarr/mqtt-streamer.lua"
upload "$SCRIPT_DIR/api-server.lua"   "/data/lamarr/api-server.lua"
remote "chmod 755 /data/lamarr/mqtt-streamer.lua /data/lamarr/api-server.lua
        chown curb:avahi /data/lamarr/mqtt-streamer.lua /data/lamarr/api-server.lua 2>/dev/null || true"
ok "Permissions set"

# ── Web pages ─────────────────────────────────────────────────────────────────
step "Uploading web pages..."
remote "mkdir -p /data/sd/www /tmp/www"
for page in energy.html stats.html settings.html calibration.html sysinfo.html serial-guide.html; do
  if [ -f "$SCRIPT_DIR/webserver/$page" ]; then
    upload "$SCRIPT_DIR/webserver/$page" "/data/sd/www/$page"
    remote "cp /data/sd/www/$page /tmp/www/$page && chmod 644 /tmp/www/$page"
  fi
done
ok "Web pages deployed"

# ── MQTT config ───────────────────────────────────────────────────────────────
step "Configuring MQTT..."
HAS_MQTT=$(remote "[ -f /data/mqtt-config.json ] && echo yes || echo no")
if [ "$HAS_MQTT" = "yes" ]; then
  warn "mqtt-config.json already exists -- keeping existing config"
  info "Edit via http://$CURB_IP/settings.html after installation"
else
  echo ""
  echo -e "  ${YELLOW}MQTT broker not configured.${NC}"
  echo -e "  You can configure it now, or skip and use the web interface later:"
  echo -e "  ${CYAN}http://$CURB_IP/settings.html${NC}"
  echo ""
  read -p "  Configure MQTT now? [Y/n]: " CONF_MQTT
  CONF_MQTT="${CONF_MQTT:-Y}"
  if [[ "$CONF_MQTT" =~ ^[Yy] ]]; then
    echo ""
    read -p "    Broker address  [10.0.0.49]:          " BROKER_HOST
    BROKER_HOST="${BROKER_HOST:-10.0.0.49}"
    read -p "    Port            [1883]:                " BROKER_PORT
    BROKER_PORT="${BROKER_PORT:-1883}"
    read -p "    Username        [mqtt_user]:           " MQTT_USER
    MQTT_USER="${MQTT_USER:-mqtt_user}"
    read -s -p "    Password:                              " MQTT_PASS; echo ""
    read -p "    Base topic      [curb/power]:          " BASE_TOPIC
    BASE_TOPIC="${BASE_TOPIC:-curb/power}"
    read -p "    Device name     [Curb Energy Monitor]: " DEV_NAME
    DEV_NAME="${DEV_NAME:-Curb Energy Monitor}"

    MQTT_PASS_ESC=$(printf '%s' "$MQTT_PASS" | sed 's/\\/\\\\/g; s/"/\\"/g')

    $SSH root@"$CURB_IP" "cat > /data/mqtt-config.json" << EOF
{
  "broker_host":  "$BROKER_HOST",
  "broker_port":  $BROKER_PORT,
  "username":     "$MQTT_USER",
  "password":     "$MQTT_PASS_ESC",
  "base_topic":   "$BASE_TOPIC",
  "ha_prefix":    "homeassistant",
  "device_name":  "$DEV_NAME"
}
EOF
    remote "chmod 600 /data/mqtt-config.json"
    ok "mqtt-config.json created (chmod 600)"
  else
    warn "MQTT not configured -- edit via http://$CURB_IP/settings.html after installation"
  fi
fi

# ── Calibration file ──────────────────────────────────────────────────────────
step "Calibration file..."
HAS_CAL=$(remote "[ -f /data/calibration.json ] && echo yes || echo no")
if [ "$HAS_CAL" = "yes" ]; then
  warn "calibration.json already exists -- keeping existing"
else
  upload "$SCRIPT_DIR/calibration.json" "/data/calibration.json"
  remote "chmod 644 /data/calibration.json"
  ok "calibration.json uploaded with default values"
  warn "Calibrate via http://$CURB_IP/calibration.html"
fi

# ── Patch hm.conf ─────────────────────────────────────────────────────────────
step "Updating /etc/hm.conf..."
dbg "Sending hm.conf patch via sh -s"
$SSH root@"$CURB_IP" 'sh -se' << 'REMOTE_HM'
#!/bin/sh
HM=/etc/hm.conf
[ -f "$HM" ] || { echo "  ERROR: $HM not found"; exit 1; }

add_entry() {
  local marker="$1" entry="$2"
  if grep -q "$marker" "$HM"; then
    echo "  Already present: $marker"; return
  fi
  awk -v e="$entry" '/^\)/ && !done { print e; done=1 } { print }' \
    "$HM" > /tmp/hm_patched.conf && cp /tmp/hm_patched.conf "$HM"
  echo "  Added: $marker"
}

add_entry "mqtt streamer" '  { name="mqtt streamer",  type="respawn", directory="/data/lamarr", command="./mqtt-streamer.lua", delay=5 },'
add_entry "api server"    '  { name="api server",     type="respawn", directory="/data/lamarr", command="./api-server.lua",    delay=6 }'
REMOTE_HM
ok "hm.conf done"

# ── Patch curb_status.sh ──────────────────────────────────────────────────────
step "Patching curb_status.sh..."
dbg "Sending curb_status.sh patch via sh -s"
$SSH root@"$CURB_IP" 'sh -se' << 'REMOTE_SH'
#!/bin/sh
SH=/usr/local/bin/curb_status.sh
[ -f "$SH" ] || { echo "  WARNING: $SH not found -- skipping"; exit 0; }

add_copy() {
  local page="$1"
  grep -q "$page" "$SH" && { echo "  Already present: $page"; return; }
  echo "[ -f /data/sd/www/$page ] && cp /data/sd/www/$page \"\$BASE_DIR/$page\" && chmod 644 \"\$BASE_DIR/$page\"" >> "$SH"
  echo "  Added: $page"
}

add_copy energy.html
add_copy settings.html
add_copy calibration.html
add_copy sysinfo.html
add_copy serial-guide.html
add_copy stats.html
REMOTE_SH
ok "curb_status.sh done"

# ── Restart processes ─────────────────────────────────────────────────────────
step "Restarting processes..."
remote '
  for proc in "mqtt-streamer.lua" "api-server.lua"; do
    PID=$(ps | grep "$proc" | grep lua | grep -v grep | sed "s/^ *//" | cut -d" " -f1)
    if [ -n "$PID" ]; then
      kill $PID 2>/dev/null && echo "  Stopped (hm will respawn): $proc"
    else
      echo "  Starting: $proc"
    fi
  done
  sleep 3
  ps | grep -E "sampler|mqtt-streamer|api-server" | grep lua | grep -v grep || echo "  (processes starting up...)"
'
ok "Processes handled"

# ── Verify ────────────────────────────────────────────────────────────────────
step "Verifying..."
sleep 4
API_OK=false
WEB_OK=false
if remote "wget -qO- http://localhost:8080/api/status 2>/dev/null" | grep -q "uptime"; then
  ok "API server responding on port 8080"
  API_OK=true
else
  warn "API server not responding yet -- hm will start it in a few seconds"
fi
if remote "[ -f /tmp/www/energy.html ]" 2>/dev/null; then
  ok "energy.html ready in /tmp/www/"
  WEB_OK=true
else
  warn "energy.html not found in /tmp/www/"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo ""
if $API_OK && $WEB_OK; then
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║                                                  ║${NC}"
  echo -e "${GREEN}${BOLD}║   ✔  Installation complete!                      ║${NC}"
  echo -e "${GREEN}${BOLD}║                                                  ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
else
  echo -e "${YELLOW}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}${BOLD}║   Installation done (with warnings -- see above) ║${NC}"
  echo -e "${YELLOW}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
fi
echo ""
echo -e "  ${BOLD}Open in browser:${NC}"
echo -e "    ${CYAN}http://$CURB_IP/energy.html${NC}       <- Dashboard"
echo -e "    ${CYAN}http://$CURB_IP/calibration.html${NC}  <- Calibration"
echo -e "    ${CYAN}http://$CURB_IP/settings.html${NC}     <- MQTT settings"
echo -e "    ${CYAN}http://$CURB_IP/sysinfo.html${NC}      <- System info"
echo -e "    ${CYAN}http://$CURB_IP/stats.html${NC}        <- Statistikk"
echo -e "    ${CYAN}http://$CURB_IP/serial-guide.html${NC} <- Serial & Powerline guide"
echo ""
echo -e "  ${BOLD}Backup:${NC} $BACKUP_DIR (on Curb device)"
echo -e "  ${BOLD}Log:${NC}    $LOG_FILE"
echo ""
echo -e "  ${CYAN}Press Enter to exit (auto-closes in 30 seconds)...${NC}"
read -t 30 || true
echo ""
