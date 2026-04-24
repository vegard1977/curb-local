#!/usr/bin/env lua
-- mqtt-streamer.lua  v1.1
-- Les fra LEGACY IPC-koe, appliser kalibrering, publiser til MQTT.
-- Sender HA auto-discovery ved oppstart.
-- Erstatter curb-to-mqtt.py (Python bridge).
-- Kjores av hm (health monitor) fra /data/lamarr/

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
logger:info('mqtt-streamer v1.1 starting...')

-- ── Config ────────────────────────────────────────────────────────────────────
local MQTT_CFG_FILE  = '/data/mqtt-config.json'
local CAL_FILE       = '/data/calibration.json'
local STATUS_JSON    = '/tmp/www/latest.json'
local RECONNECT_SECS = 5

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

local BROKER_HOST = mcfg.broker_host or 'localhost'
local BROKER_PORT = mcfg.broker_port or 1883
local MQTT_USER   = mcfg.username    or ''
local MQTT_PASS   = mcfg.password    or ''
local BASE_TOPIC  = mcfg.base_topic  or 'curb/power'
local HA_PREFIX   = mcfg.ha_prefix   or 'homeassistant'
local DEVICE_NAME = mcfg.device_name or 'Curb Energy Monitor'

-- Hent serienummer fra EEPROM (eks: 'd8gebmbg' -> 'curb_d8gebmbg')
local serial    = eeprom.get('serialNumber') or 'curb'
local DEVICE_ID = 'curb_' .. serial

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
]]

local mosq = ffi.load('mosquitto')
mosq.mosquitto_lib_init()

local client = mosq.mosquitto_new('curb-' .. os.time(), true, nil)
assert(client ~= nil, 'mosquitto_new feilet')
mosq.mosquitto_username_pw_set(client, MQTT_USER, MQTT_PASS)

local connected = false

local function mqtt_connect()
  local rc = mosq.mosquitto_connect(client, BROKER_HOST, BROKER_PORT, 60)
  if rc ~= 0 then
    logger:error('MQTT connect feilet rc=%d, prover om %ds', rc, RECONNECT_SECS)
    return false
  end
  -- Pump loopen til CONNACK er mottatt
  for _ = 1, 10 do
    mosq.mosquitto_loop(client, 50, 1)
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
    logger:warn('publish feil rc=%d topic=%s -- reconnect', rc, topic)
    connected = false
    socket.sleep(RECONNECT_SECS)
    connected = mqtt_connect()
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

-- ── Hovedloekke ───────────────────────────────────────────────────────────────
local sample_count = 0

logger:info('Starter hovedloekke')

while true do
  local sample = queue.get(qid, 2.0)

  if sample then
    local circuit = 0

    for _, group in ipairs(sample.group) do
      local voltage = group.vrms * cal.volt_scale

      for _, ch in ipairs(group.channel) do
        circuit = circuit + 1

        local data = {
          power        = math.abs(ch.watthr) * 3600 * cal.watt_scale,
          current      = math.abs(ch.irms) * current_scale(circuit),
          power_factor = math.max(-1.0, math.min(1.0, ch.powerFactor * cal.pf_scale)),
          voltage      = voltage,
          t            = sample.timestamp,
        }

        local payload = json.encode(data)
        publish(BASE_TOPIC .. '/circuit_' .. circuit, payload)
        latest_circuits[circuit] = data
      end
    end

    mosq.mosquitto_loop(client, 0, 1)
    write_latest()

    -- Send én discovery-melding per iterasjon (ikke-blokkerende)
    if #discovery_queue > 0 then
      local msg = table.remove(discovery_queue, 1)
      publish_retain(msg.topic, msg.payload)
      if #discovery_queue == 0 then
        logger:info('HA auto-discovery fullfort (%s)', DEVICE_ID)
      end
    end

    sample_count = sample_count + 1
    if sample_count % 60 == 0 then
      logger:info('%d samples publisert, %d kretser', sample_count, circuit)
    end

  else
    -- Ingen sample -- hold MQTT-tilkoblingen i live
    if connected then
      mosq.mosquitto_loop(client, 100, 1)
      -- Send discovery-meldinger sakte også her
      if #discovery_queue > 0 then
        local msg = table.remove(discovery_queue, 1)
        publish_retain(msg.topic, msg.payload)
      end
    else
      logger:warn('Ikke koblet, prover reconnect...')
      socket.sleep(RECONNECT_SECS)
      connected = mqtt_connect()
      if connected then queue_discovery() end
    end
  end
end
