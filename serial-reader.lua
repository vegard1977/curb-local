#!/usr/bin/env lua
-- serial-reader.lua  v2.0
-- Multi-device serial reader: Arduino Mega, ESP32, Arduino Uno, osv.
-- Bruker select() (FFI) for ikke-blokkerende parallell lesing fra alle porter.
-- Devices konfigureres i /data/serial-devices.json.
-- Kjores av hm (health monitor) fra /data/lamarr/

io.stdout:setvbuf('no')
io.stderr:setvbuf('no')

local ffi    = require('ffi')
local bit    = require('bit')
local json   = require('json')
local log    = require('logging')
local fileLog= require('logging.rolling_file')
local socket = require('socket')
local eeprom = require('curb-eeprom')

local logger = fileLog('/var/log/serial-reader.log', 256 * 1024, 2)
logger:setLevel(log.INFO)
logger:info('serial-reader v2.0 starting...')

-- ── FFI: open/read/close + select() ──────────────────────────────────────────
ffi.cdef[[
  int    open(const char *pathname, int flags);
  int    close(int fd);
  typedef long ssize_t;
  ssize_t read(int fd, void *buf, size_t count);

  /* fd_set: 1024 bits = 32 x uint32 on 32-bit ARM */
  typedef struct { unsigned int fds_bits[32]; } fd_set_t;
  struct timeval { long tv_sec; long tv_usec; };
  int select(int nfds, fd_set_t *, fd_set_t *, fd_set_t *, struct timeval *);

  /* mosquitto */
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

local O_RDONLY = 0
local READ_BUF = ffi.new('char[512]')

local function fd_zero(set)   ffi.fill(set, ffi.sizeof(set[0]), 0) end
local function fd_set(fd, s)  s.fds_bits[math.floor(fd/32)] = bit.bor(s.fds_bits[math.floor(fd/32)], bit.lshift(1, fd%32)) end
local function fd_isset(fd,s) return bit.band(s.fds_bits[math.floor(fd/32)], bit.lshift(1, fd%32)) ~= 0 end

-- ── Konfig ────────────────────────────────────────────────────────────────────
local DEVICES_CFG   = '/data/serial-devices.json'
local MQTT_CFG_FILE = '/data/mqtt-config.json'
local CAL_FILE      = '/data/calibration.json'
local ARDUINO_JSON  = '/tmp/www/arduino.json'
local RECONNECT_S   = 5

local function load_json(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local s = f:read('*all'); f:close()
  local ok, d = pcall(json.decode, s)
  return ok and d or nil
end

local mcfg = load_json(MQTT_CFG_FILE) or {}
local cal  = load_json(CAL_FILE)      or {}

local BROKER     = mcfg.broker_host  or 'localhost'
local PORT_N     = mcfg.broker_port  or 1883
local MQTT_USER  = mcfg.username     or ''
local MQTT_PASS  = mcfg.password     or ''
local BASE_TOPIC = mcfg.base_topic   or 'curb/power'
local HA_PREFIX  = mcfg.ha_prefix   or 'homeassistant'
local DEV_NAME   = mcfg.device_name or 'Curb Energy Monitor'

local serial    = eeprom.get('serialNumber') or 'curb'
local DEVICE_ID = 'curb_' .. serial

local function circuit_name(idx)
  if cal.circuit_names and cal.circuit_names[idx] then
    return cal.circuit_names[idx]
  end
  return 'Krets ' .. idx
end

-- ── Last device-konfig ────────────────────────────────────────────────────────
-- Leser /data/serial-devices.json.
-- Hvis filen mangler, brukes en intern standard (Arduino Mega pa /dev/ttyACM0).
local DEFAULT_DEVICES = {
  {
    port        = '/dev/ttyACM0',
    baud        = 115200,
    label       = 'Arduino Mega',
    ct_offset   = 18,        -- circuit_19 .. circuit_34
    num_ct      = 16,
    num_temp    = 2,
    temp_labels = { 'Sikringsskap topp', 'Sikringsskap bunn' },
  },
}

local dev_cfg = load_json(DEVICES_CFG) or DEFAULT_DEVICES
logger:info('Konfigurert med %d enhet(er)', #dev_cfg)

-- ── MQTT ──────────────────────────────────────────────────────────────────────
local mosq_lib = ffi.load('mosquitto')
mosq_lib.mosquitto_lib_init()
local client = mosq_lib.mosquitto_new('curb-serial-' .. os.time(), true, nil)
assert(client ~= nil, 'mosquitto_new feilet')
mosq_lib.mosquitto_username_pw_set(client, MQTT_USER, MQTT_PASS)

local connected = false

local function broker_reachable()
  local t = socket.tcp(); t:settimeout(1)
  local ok = t:connect(BROKER, PORT_N); t:close()
  return ok ~= nil
end

local function mqtt_connect()
  if not broker_reachable() then return false end
  if mosq_lib.mosquitto_connect(client, BROKER, PORT_N, 60) ~= 0 then
    logger:error('MQTT connect feilet, prover om %ds', RECONNECT_S)
    return false
  end
  for _ = 1, 20 do
    mosq_lib.mosquitto_loop(client, 50, 1)
    if mosq_lib.mosquitto_socket(client) == -1 then
      logger:warn('MQTT: broker avviste tilkobling')
      return false
    end
  end
  logger:info('MQTT koblet til %s:%d', BROKER, PORT_N)
  return true
end

connected = mqtt_connect()

local function pub(topic, payload, retain)
  if not connected then return end
  local rc = mosq_lib.mosquitto_publish(client, nil, topic, #payload, payload, 0, retain or false)
  if rc ~= 0 then
    logger:warn('publish feil rc=%d -- markerer frakoblet', rc)
    connected = false
  end
  mosq_lib.mosquitto_loop(client, 0, 1)
end

-- ── HA auto-discovery ─────────────────────────────────────────────────────────
local function send_discovery(dev)
  local device = {
    identifiers  = { DEVICE_ID },
    name         = DEV_NAME,
    model        = 'Curb',
    manufacturer = 'Curb',
  }

  -- CT-kretser (kun strom -- ingen spenning/effekt fra Arduino-siden)
  for i = 1, (dev.num_ct or 0) do
    local circuit_idx = dev.ct_offset + i
    local obj_id    = DEVICE_ID .. '_circuit_' .. circuit_idx .. '_a'
    local cfg_topic = HA_PREFIX .. '/sensor/' .. DEVICE_ID .. '/' .. obj_id .. '/config'
    pub(cfg_topic, json.encode({
      name                = circuit_name(circuit_idx) .. ' Strom',
      unique_id           = obj_id,
      state_topic         = BASE_TOPIC .. '/circuit_' .. circuit_idx,
      value_template      = '{{ value_json.current | round(3) }}',
      unit_of_measurement = 'A',
      device_class        = 'current',
      state_class         = 'measurement',
      device              = device,
    }), true)
  end

  -- Temperatursenorer
  local temp_labels = dev.temp_labels or {}
  for i = 0, (dev.num_temp or 0) - 1 do
    local label   = temp_labels[i + 1] or (dev.label .. ' temp ' .. i)
    local obj_id  = DEVICE_ID .. '_' .. dev.port:match('([^/]+)$') .. '_temp_' .. i
    local cfg_topic = HA_PREFIX .. '/sensor/' .. DEVICE_ID .. '/' .. obj_id .. '/config'
    pub(cfg_topic, json.encode({
      name                = label,
      unique_id           = obj_id,
      state_topic         = BASE_TOPIC .. '/temp/' .. dev.ct_offset .. '_' .. i,
      value_template      = '{{ value | float | round(1) }}',
      unit_of_measurement = '°C',
      device_class        = 'temperature',
      state_class         = 'measurement',
      device              = device,
    }), true)
  end

  -- AMS linjespent og fase-stroem (for ESP32 med amsreader-firmware)
  -- Spenning er linje-til-linje: U L1-L2, U L1-L3, U L2-L3
  -- L2 strom leveres av Arduino Mega, ikke AMS
  if dev.device_type == 'amsreader' then
    local ams_sensors = {
      { id='u12_v', name='AMS U L1-L2',          topic='ams/u12_v', unit='V',   cls='voltage' },
      { id='u13_v', name='AMS U L1-L3',          topic='ams/u13_v', unit='V',   cls='voltage' },
      { id='u23_v', name='AMS U L2-L3',          topic='ams/u23_v', unit='V',   cls='voltage' },
      { id='l1_i',  name='AMS L1 Strom',         topic='ams/l1_i',  unit='A',   cls='current' },
      { id='l3_i',  name='AMS L3 Strom',         topic='ams/l3_i',  unit='A',   cls='current' },
      { id='power',  name='AMS Import',           topic='ams/power', unit='W',   cls='power' },
      { id='export', name='AMS Eksport',          topic='ams/export',unit='W',   cls='power' },
      { id='q',      name='AMS Reaktiv effekt',   topic='ams/q',     unit='VAr', cls='reactive_power' },
      { id='s',      name='AMS Tilsynelatende',   topic='ams/s',     unit='VA',  cls='apparent_power' },
      { id='pf',     name='AMS Effektfaktor',     topic='ams/pf',    unit=nil,   cls='power_factor' },
      { id='phi',    name='AMS Fasevinkel',        topic='ams/phi',   unit='°',   cls=nil },
    }
    for _, s in ipairs(ams_sensors) do
      local obj_id    = DEVICE_ID .. '_' .. s.id
      local cfg_topic = HA_PREFIX .. '/sensor/' .. DEVICE_ID .. '/' .. obj_id .. '/config'
      local cfg = {
        name        = s.name,
        unique_id   = obj_id,
        state_topic = BASE_TOPIC .. '/' .. s.topic,
        state_class  = 'measurement',
        device       = device,
      }
      if s.cls  then cfg.device_class          = s.cls  end
      if s.unit then cfg.unit_of_measurement   = s.unit end
      pub(cfg_topic, json.encode(cfg), true)
    end
    logger:info('[%s] AMS discovery sendt (11 sensorer)', dev.label)
  end

  logger:info('[%s] Discovery sendt (%d CT, %d temp)', dev.label, dev.num_ct or 0, dev.num_temp or 0)
end

-- ── Apne seriell port ─────────────────────────────────────────────────────────
local function open_port(dev)
  os.execute(string.format(
    'stty -F %s %d cs8 raw -echo -cstopb -parenb 2>/dev/null',
    dev.port, dev.baud or 115200))
  local fd = ffi.C.open(dev.port, O_RDONLY)
  if fd < 0 then
    logger:error('[%s] Klarte ikke apne %s', dev.label, dev.port)
    return nil
  end
  logger:info('[%s] Apnet %s @ %d baud (fd=%d)', dev.label, dev.port, dev.baud or 115200, fd)
  return fd
end

-- ── Prosesser ei linje fra ein enhet ─────────────────────────────────────────
local function process_line(dev, line)
  line = line:gsub('\r', '')
  if line:sub(1, 1) == '#' then
    logger:info('[%s] %s', dev.label, line)
    return
  end

  local ok, data = pcall(json.decode, line)
  if not ok or type(data) ~= 'table' then
    logger:debug('[%s] Ugyldig linje: %s', dev.label, line:sub(1, 80))
    return
  end

  -- ── AMS/amsreader-format: {u12,u13,u23, i1,i3, p,px,q,s,pf,phi} ─────────
  -- Spenning er linje-til-linje. L2 strom mangler (leveres av Arduino Mega).
  -- q/s/pf/phi er beregnet i firmware fra aktiv+reaktiv effekt.
  if data.u12 ~= nil then
    dev.last_voltages       = { l1l2 = data.u12, l1l3 = data.u13 or 0, l2l3 = data.u23 or 0 }
    dev.last_phase_currents = { l1 = data.i1 or 0, l3 = data.i3 or 0 }
    dev.last_power          = data.p   or 0
    dev.last_power_export   = data.px  or 0
    dev.last_q              = data.q   or 0
    dev.last_s              = data.s   or 0
    dev.last_pf             = data.pf  or 0
    dev.last_phi            = data.phi or 0

    pub(BASE_TOPIC .. '/ams/u12_v', string.format('%.1f', data.u12))
    pub(BASE_TOPIC .. '/ams/u13_v', string.format('%.1f', data.u13 or 0))
    pub(BASE_TOPIC .. '/ams/u23_v', string.format('%.1f', data.u23 or 0))
    pub(BASE_TOPIC .. '/ams/l1_i',  string.format('%.2f', data.i1  or 0))
    pub(BASE_TOPIC .. '/ams/l3_i',  string.format('%.2f', data.i3  or 0))
    pub(BASE_TOPIC .. '/ams/power',  tostring(data.p  or 0))
    pub(BASE_TOPIC .. '/ams/export', tostring(data.px or 0))
    pub(BASE_TOPIC .. '/ams/q',      tostring(data.q  or 0))
    pub(BASE_TOPIC .. '/ams/s',      string.format('%.0f', data.s  or 0))
    pub(BASE_TOPIC .. '/ams/pf',     string.format('%.3f', data.pf or 0))
    pub(BASE_TOPIC .. '/ams/phi',    string.format('%.1f', data.phi or 0))

    logger:debug('[%s] AMS U12=%.1f U13=%.1f U23=%.1f V  I1=%.2f I3=%.2f A  P=%d Q=%d S=%.0f VA  PF=%.3f  phi=%.1f°',
      dev.label,
      data.u12, data.u13 or 0, data.u23 or 0,
      data.i1 or 0, data.i3 or 0,
      data.p or 0, data.q or 0, data.s or 0,
      data.pf or 0, data.phi or 0)
    return
  end

  -- ── Arduino-format: {t, a} (temperaturar + CT-straum) ───────────────────
  local temps = data.t or {}
  local amps  = data.a or {}

  -- Temperatur: topic skiljer enheter via ct_offset-prefiks
  for i, v in ipairs(temps) do
    if v ~= json.null then
      pub(BASE_TOPIC .. '/temp/' .. dev.ct_offset .. '_' .. (i - 1), tostring(v))
    end
  end

  -- CT-kretser
  for i, v in ipairs(amps) do
    local circuit_idx = dev.ct_offset + i
    pub(BASE_TOPIC .. '/circuit_' .. circuit_idx, json.encode({ current = v }))
  end

  -- Oppdater arduino.json (siste kjente verdier fraa alle enheter)
  dev.last_temps = temps
  dev.last_amps  = amps

  logger:debug('[%s] OK: %d temp, %d CT', dev.label, #temps, #amps)
end

local function write_combined_json(devices)
  local out = { devices = {} }
  for _, d in ipairs(devices) do
    local entry = {
      label       = d.label,
      port        = d.port,
      ct_offset   = d.ct_offset,
      temp_labels = d.temp_labels or {},
      temps       = d.last_temps  or {},
      amps        = d.last_amps   or {},
    }
    if d.last_voltages then
      entry.voltages       = d.last_voltages
      entry.phase_currents = d.last_phase_currents or {}
      entry.active_power   = d.last_power        or 0
      entry.export_power   = d.last_power_export  or 0
      entry.reactive_power = d.last_q             or 0
      entry.apparent_power = d.last_s             or 0
      entry.power_factor   = d.last_pf            or 0
      entry.phase_angle    = d.last_phi           or 0
    end
    out.devices[#out.devices + 1] = entry
  end
  out.ts = os.time()
  local f = io.open(ARDUINO_JSON, 'w')
  if f then
    f:write(json.encode(out)); f:close()
    os.execute('chmod 644 ' .. ARDUINO_JSON)
  end
end

-- ── Hoved-loop: open alle porter, select() parallelt ─────────────────────────
if connected then
  for _, d in ipairs(dev_cfg) do send_discovery(d) end
end

-- Apne alle konfigurerte porter
for _, d in ipairs(dev_cfg) do
  d.fd  = open_port(d)
  d.buf = ''
end

local last_reconnect = 0

while true do
  -- MQTT reconnect ved behov
  if not connected and (os.time() - last_reconnect) >= RECONNECT_S then
    last_reconnect = os.time()
    connected = mqtt_connect()
    if connected then
      for _, d in ipairs(dev_cfg) do send_discovery(d) end
    end
  end

  -- Bygg fd_set for alle opne porter
  local readfds = ffi.new('fd_set_t')
  local maxfd   = -1
  local any_open = false

  for _, d in ipairs(dev_cfg) do
    if d.fd and d.fd >= 0 then
      fd_set(d.fd, readfds)
      if d.fd > maxfd then maxfd = d.fd end
      any_open = true
    end
  end

  if not any_open then
    -- Ingen apne porter -- vent og prøv på nytt
    socket.sleep(RECONNECT_S)
    for _, d in ipairs(dev_cfg) do
      if not d.fd or d.fd < 0 then
        d.fd  = open_port(d)
        d.buf = ''
      end
    end
  else
    -- select() med 2s timeout
    local tv = ffi.new('struct timeval', { tv_sec = 2, tv_usec = 0 })
    local n  = ffi.C.select(maxfd + 1, readfds, nil, nil, tv)

    if n > 0 then
      for _, d in ipairs(dev_cfg) do
        if d.fd and d.fd >= 0 and fd_isset(d.fd, readfds) then
          local bytes = ffi.C.read(d.fd, READ_BUF, 511)
          if bytes <= 0 then
            logger:warn('[%s] read() returnerte %d -- lukker port', d.label, bytes)
            ffi.C.close(d.fd)
            d.fd = nil
          else
            d.buf = d.buf .. ffi.string(READ_BUF, bytes)
            -- Trekk ut komplette linjer
            while true do
              local nl = d.buf:find('\n')
              if not nl then break end
              local line = d.buf:sub(1, nl - 1)
              d.buf = d.buf:sub(nl + 1)
              process_line(d, line)
            end
            write_combined_json(dev_cfg)
          end
        end
      end
    end

    -- Forsøk å gjenåpne stengde porter
    for _, d in ipairs(dev_cfg) do
      if not d.fd or d.fd < 0 then
        socket.sleep(RECONNECT_S)
        d.fd  = open_port(d)
        d.buf = ''
        if d.fd and connected then send_discovery(d) end
      end
    end

    mosq_lib.mosquitto_loop(client, 0, 1)
  end
end

mosq_lib.mosquitto_lib_cleanup()
