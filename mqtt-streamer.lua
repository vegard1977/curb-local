#!/usr/bin/env lua
-- mqtt-streamer.lua  v1.4
-- Les fra LEGACY IPC-koe, appliser kalibrering, publiser til MQTT.
-- Sender HA auto-discovery ved oppstart.
-- Erstatter curb-to-mqtt.py (Python bridge).
-- Kjores av hm (health monitor) fra /data/lamarr/
--
-- Endringslogg v1.4:
--   - Daglig arkivering til history.json ved midnatt (per-krets, maks 365 dager)
--   - history.json kopieres til webroot ved oppstart (leses av stats.html)
-- Endringslogg v1.3:
--   - Daglig kWh-akkumulering per krets (uavhengig av nettleser)
--   - Skriver /tmp/www/daily.json hvert publish-intervall (webgrensesnitt)
--   - Lagrer /data/daily.json hvert 5. minutt (overlever reboot)
--   - Nullstiller automatisk ved midnatt og leser videre etter restart
-- Endringslogg v1.2:
--   - TCP pre-sjekk (1s timeout) foer mosquitto_connect() -- forhindrer 2+ min OS-hang
--   - publish_raw() kobler ikke lenger ut i inline sleep/reconnect -- main-loop tar det
--   - Konfigurerbar publish_interval (standard 5s) -- reduserer MQTT-trykk mot HA

io.stdout:setvbuf('no')
io.stderr:setvbuf('no')

local ffi      = require('ffi')
local json     = require('json')
local queue    = require('queue')
local logging  = require('logging')
local fileLog  = require('logging.rolling_file')
local socket   = require('socket')
local eeprom   = require('curb-eeprom')

local logger = fileLog('/var/log/mqtt-streamer.log', 512 * 1024, 2)
logger:setLevel(logging.INFO)
logger:info('mqtt-streamer v1.4 starting...')

-- ── Config ────────────────────────────────────────────────────────────────────
local MQTT_CFG_FILE  = '/data/mqtt-config.json'
local CAL_FILE       = '/data/calibration.json'
local STATUS_JSON      = '/tmp/www/latest.json'
local SYSINFO_JSON     = '/tmp/www/sysinfo.json'  -- leses av lighttpd (web)
local DAILY_JSON_TMP   = '/tmp/www/daily.json'   -- leses av lighttpd (web)
local DAILY_JSON_DATA  = '/data/daily.json'      -- persistent, overlever reboot
local DAILY_SAVE_SECS  = 300                     -- skriv til /data/ hvert 5. minutt
local HISTORY_JSON_TMP  = '/tmp/www/history.json' -- leses av lighttpd (web)
local HISTORY_JSON_DATA = '/data/history.json'    -- persistent
local HISTORY_MAX_DAYS  = 365                     -- maks dager i history
local RECONNECT_SECS   = 5
local CONNECT_TIMEOUT = 1   -- sekunder foer vi gir opp TCP pre-sjekk

local function load_mqtt_config()
  local f = io.open(MQTT_CFG_FILE, 'r')
  if not f then
    logger:warn('Fant ikke %s, bruker standardverdier', MQTT_CFG_FILE)
    return {
      broker_host = 'localhost', broker_port = 1883,
      username = '', password = '',
      base_topic = 'curb/power', ha_prefix = 'homeassistant',
      device_name = 'Curb Energy Monitor',
    }
  end
  local cfg = json.decode(f:read('*all'))
  f:close()
  logger:info('MQTT-konfig lastet fra %s', MQTT_CFG_FILE)
  return cfg
end

local mcfg = load_mqtt_config()

local BROKER_HOST      = mcfg.broker_host      or 'localhost'
local BROKER_PORT      = mcfg.broker_port      or 1883
local MQTT_USER        = mcfg.username         or ''
local MQTT_PASS        = mcfg.password         or ''
local BASE_TOPIC       = mcfg.base_topic       or 'curb/power'
local HA_PREFIX        = mcfg.ha_prefix        or 'homeassistant'
local DEVICE_NAME      = mcfg.device_name      or 'Curb Energy Monitor'
local PUBLISH_INTERVAL = mcfg.publish_interval or 5   -- sekunder mellom MQTT-publisering

-- Hent enhetsinformasjon fra EEPROM og systemfiler (leses kun ved oppstart)
local serial      = eeprom.get('serialNumber')    or 'curb'
local hw_version  = eeprom.get('hardwareVersion') or '—'
local DEVICE_ID   = 'curb_' .. serial

local function read_oneliner(path)
  local f = io.open(path, 'r')
  if not f then return '—' end
  local s = f:read('*l'); f:close()
  return (s and s:match('^%s*(.-)%s*$')) or '—'
end
local os_version  = read_oneliner('/etc/os_version')
local sw_version  = read_oneliner('/data/software_version')

-- ── Kalibrering ───────────────────────────────────────────────────────────────
local function load_calibration()
  local f = io.open(CAL_FILE, 'r')
  if not f then
    logger:warn('Fant ikke %s, bruker standardverdier', CAL_FILE)
    return {
      volt_scale  = 0.0000848,
      watt_scale  = 0.001,
      pf_scale    = 0.000030518,
      circuit_current_scales = {},
    }
  end
  local data = json.decode(f:read('*all'))
  f:close()
  logger:info('Kalibrering lastet fra %s', CAL_FILE)
  return data
end

local cal = load_calibration()

local function current_scale(idx)
  local s = cal.circuit_current_scales
  return (s and s[idx]) or 1.0
end

-- ── libmosquitto FFI ──────────────────────────────────────────────────────────
ffi.cdef[[
  int  mosquitto_lib_init(void);
  int  mosquitto_lib_cleanup(void);
  typedef struct mosquitto mosquitto;
  mosquitto* mosquitto_new(const char *id, bool clean_session, void *userdata);
  void       mosquitto_destroy(mosquitto *mosq);
  int  mosquitto_username_pw_set(mosquitto *mosq, const char *u, const char *p);
  int  mosquitto_connect(mosquitto *mosq, const char *host, int port, int keepalive);
  int  mosquitto_disconnect(mosquitto *mosq);
  int  mosquitto_reconnect(mosquitto *mosq);
  int  mosquitto_publish(mosquitto *mosq, int *mid, const char *topic,
                         int payloadlen, const void *payload, int qos, bool retain);
  int  mosquitto_loop(mosquitto *mosq, int timeout, int max_packets);
  int  mosquitto_socket(mosquitto *mosq);
]]

local mosq = ffi.load('mosquitto')
mosq.mosquitto_lib_init()

local client = mosq.mosquitto_new('curb-' .. os.time(), true, nil)
assert(client ~= nil, 'mosquitto_new feilet')
mosq.mosquitto_username_pw_set(client, MQTT_USER, MQTT_PASS)

local connected = false

-- TCP pre-sjekk: rask 1s timeout foer vi prover mosquitto_connect().
-- Hindrer at OS-TCP-timeout (2+ min) blokkerer hele streameren.
local function broker_reachable()
  local t = socket.tcp()
  t:settimeout(CONNECT_TIMEOUT)
  local ok, err = t:connect(BROKER_HOST, BROKER_PORT)
  t:close()
  if not ok then
    logger:warn('Broker %s:%d ikke naebar: %s', BROKER_HOST, BROKER_PORT, tostring(err))
  end
  return ok ~= nil
end

local function mqtt_connect()
  if not broker_reachable() then
    return false
  end
  local rc = mosq.mosquitto_connect(client, BROKER_HOST, BROKER_PORT, 60)
  if rc ~= 0 then
    logger:error('MQTT connect feilet rc=%d, prover om %ds', rc, RECONNECT_SECS)
    return false
  end
  -- Pump loopen til CONNACK er mottatt (maks 1s = 20 x 50ms).
  -- mosquitto_socket() returnerer -1 hvis broker lukket socketen
  -- (feil passord, ACL-avvisning o.l.) -- da returnerer vi false med en gang.
  for _ = 1, 20 do
    mosq.mosquitto_loop(client, 50, 1)
    if mosq.mosquitto_socket(client) == -1 then
      logger:warn('MQTT: socket lukket under CONNACK-pump -- broker avviste tilkobling')
      return false
    end
  end
  logger:info('MQTT koblet til %s:%d', BROKER_HOST, BROKER_PORT)
  return true
end

connected = mqtt_connect()

-- ── Publiser hjelpefunksjoner ─────────────────────────────────────────────────
local function publish_raw(topic, payload, retain)
  if not connected then return end
  local rc = mosq.mosquitto_publish(client, nil, topic, #payload, payload, 0, retain)
  if rc ~= 0 then
    logger:warn('publish feil rc=%d topic=%s -- markerer frakoblet', rc, topic)
    connected = false
    -- Ingen inline sleep/reconnect her -- main-loop tar seg av det
    -- slik at sample-prosessering ikke blokkeres
  end
end

local function publish(topic, payload)
  publish_raw(topic, payload, false)
end

local function publish_retain(topic, payload)
  publish_raw(topic, payload, true)
end

-- ── HA Auto-discovery ─────────────────────────────────────────────────────────
-- Sendes ved oppstart og etter reconnect.
-- 18 kretser x 4 sensorer = 72 discovery-meldinger.

local SENSOR_TYPES = {
  { suffix = '',    name_suffix = '',              unit = 'W',   device_class = 'power',        value_template = '{{ value_json.power | round(1) }}' },
  { suffix = '_a',  name_suffix = ' Strom',        unit = 'A',   device_class = 'current',      value_template = '{{ value_json.current | round(3) }}' },
  { suffix = '_pf', name_suffix = ' Effektfaktor', unit = nil,   device_class = 'power_factor', value_template = '{{ value_json.power_factor | round(3) }}' },
  { suffix = '_v',  name_suffix = ' Spenning',     unit = 'V',   device_class = 'voltage',      value_template = '{{ value_json.voltage | round(1) }}' },
}

-- Discovery-koe: fylles opp og sendes én melding per main-loop-iterasjon
-- slik at streameren ikke blokkerer i 60+ sekunder ved oppstart/reconnect.
local discovery_queue = {}

local function queue_discovery()
  local device = {
    identifiers  = { DEVICE_ID },
    name         = DEVICE_NAME,
    model        = 'Curb',
    manufacturer = 'Curb',
  }

  for i = 1, 18 do
    local circuit_name = 'Krets ' .. i
    if cal.circuit_names and cal.circuit_names[i] then
      circuit_name = cal.circuit_names[i]
    end
    local state_topic = BASE_TOPIC .. '/circuit_' .. i

    for _, st in ipairs(SENSOR_TYPES) do
      local obj_id  = DEVICE_ID .. '_circuit_' .. i .. st.suffix
      local topic   = HA_PREFIX .. '/sensor/' .. DEVICE_ID .. '/' .. obj_id .. '/config'
      local payload = {
        name           = circuit_name .. st.name_suffix,
        unique_id      = obj_id,
        state_topic    = state_topic,
        value_template = st.value_template,
        device_class   = st.device_class,
        state_class    = 'measurement',
        device         = device,
      }
      if st.unit then
        payload['unit_of_measurement'] = st.unit
      end
      discovery_queue[#discovery_queue + 1] = { topic = topic, payload = json.encode(payload) }
    end
  end
  logger:info('Discovery koe fylt (%d meldinger)', #discovery_queue)
end

-- Koe discovery ved oppstart
if connected then queue_discovery() end

-- ── IPC-koe ───────────────────────────────────────────────────────────────────
local qid = queue.init(queue.LEGACY_KEY)
if qid == nil then
  logger:error('LEGACY-koe init feilet')
  os.exit(1)
end
logger:info('IPC LEGACY-koe klar (key=%d)', queue.LEGACY_KEY)

-- ── Skriv latest.json for web-grensesnitt ────────────────────────────────────
local latest_circuits = {}

local function write_latest()
  local f = io.open(STATUS_JSON, 'w')
  if not f then return end
  f:write(json.encode({ circuits = latest_circuits, t = os.time() }))
  f:close()
  -- Sett rettigheter slik at lighttpd kan lese
  os.execute('chmod 644 ' .. STATUS_JSON)
end

-- ── Daglig kWh-akkumulering ───────────────────────────────────────────────────
-- Akkumulerer W*dt/3600000 per krets kont inuerlig, uavhengig av nettleser.
-- Skriver /tmp/www/daily.json hvert publish-intervall (leses av stats.html via lighttpd).
-- Lagrer /data/daily.json hvert DAILY_SAVE_SECS sekund (persistent over reboot).
-- Nullstiller automatisk ved midnatt.

local function today_str()
  return os.date('%Y-%m-%d')
end

local function load_daily()
  local f = io.open(DAILY_JSON_DATA, 'r')
  if not f then return nil end
  local s = f:read('*all'); f:close()
  local ok, d = pcall(json.decode, s)
  if not ok or type(d) ~= 'table' then return nil end
  if d.date ~= today_str() then
    logger:info('Lagret dag (%s) er ikke i dag -- starter frisk', tostring(d.date))
    return nil
  end
  logger:info('Daglig kWh lest fra %s (%s)', DAILY_JSON_DATA, d.date)
  return d
end

local daily            = load_daily() or { date = today_str(), kwh = {}, hours = {}, t = os.time() }
if not daily.hours then daily.hours = {} end   -- bakoverkompatibel med gammel JSON uten hours
for i = 1, 18 do daily.kwh[i]   = daily.kwh[i]   or 0.0 end
for i = 1, 24 do daily.hours[i] = daily.hours[i] or 0.0 end

local last_daily_save  = 0     -- siste gang vi skrev til /data/
local daily_last_t     = nil   -- tidspunkt for forrige kWh-integrasjon

local function write_daily()
  daily.t = os.time()
  local s = json.encode(daily)
  -- Alltid: skriv til live webroot (leses av stats.html)
  local f = io.open(DAILY_JSON_TMP, 'w')
  if f then
    f:write(s); f:close()
    os.execute('chmod 644 ' .. DAILY_JSON_TMP)
  end
  -- Periodisk: skriv til persistent lagring
  if daily.t - last_daily_save >= DAILY_SAVE_SECS then
    f = io.open(DAILY_JSON_DATA, 'w')
    if f then f:write(s); f:close() end
    last_daily_save = daily.t
    logger:info('Daglig kWh persistert til %s', DAILY_JSON_DATA)
  end
end

local last_sample_t   = nil  -- tidspunkt for siste mottatte sample (settes i main-loop)

-- ── Systeminformasjon til web ─────────────────────────────────────────────────
-- Skriver /tmp/www/sysinfo.json hvert publish-intervall.
-- Leser /proc/* direkte -- ingen shell-kall, ingen api-server nodvendig.

local function read_proc(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local s = f:read('*all'); f:close()
  return s
end

local function get_network_info()
  local net = { interfaces = {} }

  -- IP-adresse: foerste ikke-loopback "host LOCAL" fra fib_trie
  local f = io.open('/proc/net/fib_trie', 'r')
  if f then
    local last_ip, in_local = nil, false
    for line in f:lines() do
      if line:match('^Local:') then in_local = true end
      if in_local then
        local ip = line:match('|%-%- (%d+%.%d+%.%d+%.%d+)')
        if ip then last_ip = ip end
        if last_ip and line:match('/32 host LOCAL') then
          if not last_ip:match('^127%.') then net.ip = last_ip; break end
          last_ip = nil
        end
      end
    end
    f:close()
  end

  -- Trafikk-statistikk inkl. drops fra /proc/net/dev
  -- Felt: name rx_bytes rx_pkts rx_errs rx_drop ... tx_bytes tx_pkts tx_errs tx_drop
  local stats = {}
  f = io.open('/proc/net/dev', 'r')
  if f then
    f:read('*l'); f:read('*l')
    for line in f:lines() do
      local name, rxb, rxd, txb, txd = line:match(
        '^%s*(%S+):%s*(%d+)%s+%d+%s+%d+%s+(%d+)%s+%d+%s+%d+%s+%d+%s+%d+%s+(%d+)%s+%d+%s+%d+%s+(%d+)')
      if name and name ~= 'lo' and name ~= 'can0' and name ~= 'can1' then
        stats[name] = {
          rx_bytes = tonumber(rxb), rx_drop = tonumber(rxd),
          tx_bytes = tonumber(txb), tx_drop = tonumber(txd),
        }
      end
    end
    f:close()
  end

  -- Per-grensesnitt-info fra sysfs
  for _, iface in ipairs({'eth0', 'eth1'}) do
    local info = { name = iface }
    f = io.open('/sys/class/net/' .. iface .. '/address', 'r')
    if f then info.mac = (f:read('*l') or ''):match('^%s*(.-)%s*$'); f:close() end
    f = io.open('/sys/class/net/' .. iface .. '/operstate', 'r')
    if f then info.state = (f:read('*l') or ''):match('^%s*(.-)%s*$'); f:close() end
    if stats[iface] then
      info.rx_bytes = stats[iface].rx_bytes
      info.tx_bytes = stats[iface].tx_bytes
      info.rx_drop  = stats[iface].rx_drop
      info.tx_drop  = stats[iface].tx_drop
    end
    net.interfaces[#net.interfaces + 1] = info
  end

  return net
end

-- PLC-informasjon (cachet hvert 5. minutt -- plcstat er treg)
local plc_cache      = nil
local plc_cache_t    = 0
local PLC_CACHE_SECS = 300

local function get_plc_info()
  local plc = {}

  -- Grunnleggende enhetsinfo (plctool -I)
  local f = io.popen('/usr/local/bin/plctool -I 2>/dev/null')
  if f then
    for line in f:lines() do
      local v
      v = line:match('^NET%s+(.+)'); if v then plc.net = v end
      v = line:match('^USR%s+(.+)'); if v then plc.usr = v end
    end
    f:close()
  end

  -- Linkstatus: CCO MAC + TX/RX signal (plcstat -s 0xFC -d both -t)
  f = io.popen('/usr/local/bin/plcstat -s 0xFC -d both -t 2>/dev/null')
  if f then
    for line in f:lines() do
      -- Format: REM CCO 001 <cco_mac> <bda> <tx_snr> <rx_snr> <chipset> ...
      local cco, tx, rx = line:match('REM%s+CCO%s+%d+%s+(%S+)%s+%S+%s+(%d+)%s+(%d+)')
      if cco then
        plc.cco_mac = cco
        plc.tx_snr  = tonumber(tx)
        plc.rx_snr  = tonumber(rx)
      end
    end
    f:close()
  end

  return plc
end

local function disk_usage(path)
  local f = io.popen('df -k ' .. path .. ' 2>/dev/null | tail -1')
  if not f then return nil end
  local line = f:read('*l'); f:close()
  if not line then return nil end
  local total, used, avail = line:match('%s+(%d+)%s+(%d+)%s+(%d+)')
  if total then
    return { total_kb = tonumber(total), used_kb = tonumber(used), avail_kb = tonumber(avail) }
  end
  return nil
end

local function write_sysinfo()
  local info = {
    streamer_running = true,
    lua_version      = _VERSION,
    serial           = serial,
    hw_version       = hw_version,
    os_version       = os_version,
    sw_version       = sw_version,
    t                = os.time(),
  }

  -- Oppetid
  local ut = read_proc('/proc/uptime')
  if ut then info.uptime_secs = tonumber(ut:match('^(%S+)')) end

  -- Minne
  local mi = read_proc('/proc/meminfo')
  if mi then
    info.mem_total_kb = tonumber(mi:match('MemTotal:%s+(%d+)'))
    info.mem_avail_kb = tonumber(mi:match('MemAvailable:%s+(%d+)'))
                     or tonumber(mi:match('MemFree:%s+(%d+)'))
  end

  -- CPU-last
  local la = read_proc('/proc/loadavg')
  if la then
    local a, b, c = la:match('^(%S+)%s+(%S+)%s+(%S+)')
    info.load_1m = tonumber(a); info.load_5m = tonumber(b); info.load_15m = tonumber(c)
  end

  -- Dataalder og sampler-status
  if last_sample_t then
    info.data_age_secs   = os.time() - last_sample_t
    info.sampler_running = info.data_age_secs < 30
  else
    info.data_age_secs   = nil
    info.sampler_running = false
  end

  -- Lagringsplass (/data og /data/sd)
  info.disk_data = disk_usage('/data')
  info.disk_sd   = disk_usage('/data/sd')

  -- Nettverksinfo
  info.net = get_network_info()

  -- PLC (cachet -- plcstat er treg, kjoeres maks hvert PLC_CACHE_SECS sekund)
  if os.time() - plc_cache_t >= PLC_CACHE_SECS then
    plc_cache   = get_plc_info()
    plc_cache_t = os.time()
  end
  if plc_cache then info.plc = plc_cache end

  local f = io.open(SYSINFO_JSON, 'w')
  if f then
    f:write(json.encode(info)); f:close()
    os.execute('chmod 644 ' .. SYSINFO_JSON)
  end
end

-- Skriv sysinfo ved oppstart slik at siden ikke maa vente paa foerste publish
write_sysinfo()

-- ── Historikk (daglige totaler) ───────────────────────────────────────────────
-- Arkiverer per-krets kWh for kvar dag ved midnatt.
-- Holdes i /data/history.json (maks 365 dager) og kopieres til /tmp/www/.

local function load_history()
  local f = io.open(HISTORY_JSON_DATA, 'r')
  if not f then return { days = {} } end
  local s = f:read('*all'); f:close()
  local ok, d = pcall(json.decode, s)
  if not ok or type(d) ~= 'table' or type(d.days) ~= 'table' then
    return { days = {} }
  end
  return d
end

local function save_history(h)
  local s = json.encode(h)
  local f = io.open(HISTORY_JSON_DATA, 'w')
  if f then f:write(s); f:close() end
  f = io.open(HISTORY_JSON_TMP, 'w')
  if f then
    f:write(s); f:close()
    os.execute('chmod 644 ' .. HISTORY_JSON_TMP)
  end
end

local function archive_day(d)
  -- Fjern evt. duplikat for samme dato (ved restart same dag)
  local h = load_history()
  for i = #h.days, 1, -1 do
    if h.days[i].date == d.date then table.remove(h.days, i) end
  end
  -- Legg til ny post
  local entry = { date = d.date, kwh = {} }
  for i = 1, 18 do entry.kwh[i] = d.kwh[i] or 0.0 end
  h.days[#h.days + 1] = entry
  -- Behold kun de siste HISTORY_MAX_DAYS dagene
  while #h.days > HISTORY_MAX_DAYS do table.remove(h.days, 1) end
  save_history(h)
  logger:info('Dag %s arkivert til history.json (%d dager totalt)', d.date, #h.days)
end

-- Kopier eksisterende history til webroot ved oppstart
do
  local f = io.open(HISTORY_JSON_DATA, 'r')
  if f then
    local s = f:read('*all'); f:close()
    local fw = io.open(HISTORY_JSON_TMP, 'w')
    if fw then
      fw:write(s); fw:close()
      os.execute('chmod 644 ' .. HISTORY_JSON_TMP)
    end
    logger:info('history.json kopiert til webroot')
  end
end

-- ── Hovedloekke ───────────────────────────────────────────────────────────────
local sample_count    = 0
local last_publish    = 0   -- timestamp for siste MQTT-publisering

logger:info('Starter hovedloekke (publish_interval=%ds)', PUBLISH_INTERVAL)

while true do
  local sample = queue.get(qid, 2.0)

  if sample then
    local circuit = 0

    for _, group in ipairs(sample.group) do
      local voltage = group.vrms * cal.volt_scale

      for _, ch in ipairs(group.channel) do
        circuit = circuit + 1

        latest_circuits[circuit] = {
          power        = math.abs(ch.watthr) * 3600 * cal.watt_scale,
          current      = math.abs(ch.irms) * current_scale(circuit),
          power_factor = math.max(-1.0, math.min(1.0, ch.powerFactor * cal.pf_scale)),
          voltage      = voltage,
          t            = sample.timestamp,
        }
      end
    end

    -- Oppdater web-grensesnitt ved hvert sample (1/sek)
    write_latest()
    last_sample_t = os.time()

    -- kWh-akkumulering (hvert sample, ca 1/sek)
    local now = os.time()
    local today_s = today_str()
    if today_s ~= daily.date then
      -- Midnatt -- arkiver gammel dag til history og start ny
      archive_day(daily)
      logger:info('Midnatt -- ny dag %s, nullstiller kWh', today_s)
      daily = { date = today_s, kwh = {}, hours = {}, t = now }
      for i = 1, 18 do daily.kwh[i]   = 0.0 end
      for i = 1, 24 do daily.hours[i] = 0.0 end
      daily_last_t = nil
      last_daily_save = now
    end
    if daily_last_t ~= nil then
      local dt = math.min(now - daily_last_t, 15)  -- maks 15s gap (unngaar spike etter pause)
      if dt > 0.1 then
        local hour = tonumber(os.date('%H')) + 1  -- 1-indeksert (1-24)
        local step_kwh = 0.0
        for i, c in pairs(latest_circuits) do
          local inc = (c.power or 0.0) * dt / 3600000.0
          daily.kwh[i]  = daily.kwh[i] + inc
          step_kwh = step_kwh + inc
        end
        daily.hours[hour] = (daily.hours[hour] or 0.0) + step_kwh
      end
    end
    daily_last_t = now

    -- Publiser til MQTT kun hvert PUBLISH_INTERVAL sekund
    if now - last_publish >= PUBLISH_INTERVAL then
      for i, data in pairs(latest_circuits) do
        publish(BASE_TOPIC .. '/circuit_' .. i, json.encode(data))
      end
      last_publish = now

      -- Skriv daily.json og sysinfo.json til web og evt. /data/
      write_daily()
      write_sysinfo()

      mosq.mosquitto_loop(client, 0, 1)

      -- Send én discovery-melding per publiserings-runde (ikke-blokkerende)
      if #discovery_queue > 0 then
        local msg = table.remove(discovery_queue, 1)
        publish_retain(msg.topic, msg.payload)
        if #discovery_queue == 0 then
          logger:info('HA auto-discovery fullfort (%s)', DEVICE_ID)
        end
      end

      sample_count = sample_count + 1
      if sample_count % 60 == 0 then
        logger:info('%d publiseringer, %d kretser, interval=%ds',
          sample_count, circuit, PUBLISH_INTERVAL)
      end
    end

  else
    -- Ingen sample -- hold MQTT-tilkoblingen i live
    if connected then
      mosq.mosquitto_loop(client, 100, 1)
      -- Send discovery-meldinger sakte ogsaa her
      if #discovery_queue > 0 then
        local msg = table.remove(discovery_queue, 1)
        publish_retain(msg.topic, msg.payload)
      end
    else
      logger:warn('Ikke koblet, prover reconnect om %ds...', RECONNECT_SECS)
      socket.sleep(RECONNECT_SECS)
      connected = mqtt_connect()
      if connected then queue_discovery() end
    end
  end
end
