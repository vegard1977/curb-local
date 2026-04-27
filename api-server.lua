#!/usr/bin/env lua
-- api-server.lua  v1.2
-- Minimal HTTP API-server for Curb web-grensesnitt (port 8080).
-- Styres av hm (health monitor) fra /data/lamarr/
--
-- Endepunkter:
--   GET  /api/data           Siste maaledata (latest.json)
--   GET  /api/calibration    Les kalibreringsfil
--   POST /api/calibration    Lagre kalibreringsfil + restart streamer
--   GET  /api/mqtt           Les MQTT-konfig (passord maskert)
--   POST /api/mqtt           Lagre MQTT-konfig + restart streamer
--   GET  /api/status         Systemstatus

io.stdout:setvbuf('no')
io.stderr:setvbuf('no')

local socket  = require('socket')
local json    = require('json')
local logging = require('logging')
local fileLog = require('logging.rolling_file')

local logger = fileLog('/var/log/api-server.log', 256 * 1024, 2)
logger:setLevel(logging.INFO)
logger:info('api-server v1.2 starting on port 8080')

-- ── Filer ─────────────────────────────────────────────────────────────────────
local WEB_VERSION = 'v1.2'
local CAL_FILE    = '/data/calibration.json'
local MQTT_FILE   = '/data/mqtt-config.json'
local DATA_FILE   = '/tmp/www/latest.json'
local STREAMER    = 'mqtt-streamer.lua'

-- ── Hjelpere ──────────────────────────────────────────────────────────────────
local function read_file(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local s = f:read('*all')
  f:close()
  return s
end

local function write_file(path, content)
  local f = io.open(path, 'w')
  if not f then return false, 'Klarte ikke aapne fil: ' .. path end
  f:write(content)
  f:close()
  return true
end

-- Finn PID ved aa lese /proc/PID/cmdline direkte -- ingen shell-spawn, ingen heng-risiko.
-- cmdline er null-separert, men string.find fungerer likevel paa substrings.
local function find_pid(name)
  for pid = 1, 32768 do
    local f = io.open('/proc/' .. pid .. '/cmdline', 'r')
    if f then
      local cmd = f:read('*all'); f:close()
      if cmd:find(name, 1, true) and cmd:find('lua', 1, true) then
        return pid
      end
    end
  end
  return nil
end

local function proc_running(name)
  return find_pid(name) ~= nil
end

local function restart_streamer()
  local pid = find_pid(STREAMER)
  if pid then
    os.execute('kill ' .. pid)   -- enkelt kill, ingen pipeline
    logger:info('Sendt SIGTERM til %s (PID %d), hm respawner', STREAMER, pid)
  else
    logger:warn('restart_streamer: fant ikke prosess %s', STREAMER)
  end
end

-- ── HTTP hjelpere ─────────────────────────────────────────────────────────────
local function send_response(client, status, ctype, body)
  local headers = table.concat({
    'HTTP/1.1 ' .. status,
    'Content-Type: ' .. ctype,
    'Content-Length: ' .. #body,
    'Access-Control-Allow-Origin: *',
    'Access-Control-Allow-Methods: GET, POST, OPTIONS',
    'Access-Control-Allow-Headers: Content-Type',
    'Cache-Control: no-cache',
    'Connection: close',
    '', '',
  }, '\r\n')
  client:send(headers)
  client:send(body)
end

local function json_ok(client, data)
  send_response(client, '200 OK', 'application/json', json.encode(data))
end

local function json_err(client, status, msg)
  send_response(client, status, 'application/json', json.encode({ error = msg }))
end

-- ── Request parser ────────────────────────────────────────────────────────────
local function parse_request(client)
  client:settimeout(2)   -- 2s maks per receive -- begrenser freeze ved treg/hengende klient
  local line, err = client:receive('*l')
  if not line then return nil end

  local method, path = line:match('^(%u+) ([^ ]+)')
  if not method then return nil end

  -- Headers
  local content_length = 0
  while true do
    line = client:receive('*l')
    if not line or line == '' or line == '\r' then break end
    local k, v = line:match('^([^:]+):%s*(.-)%s*$')
    if k and k:lower() == 'content-length' then
      content_length = tonumber(v) or 0
    end
  end

  -- Body
  local body = ''
  if content_length > 0 then
    body = client:receive(content_length) or ''
  end

  return { method = method, path = path, body = body }
end

-- ── Route handlers ────────────────────────────────────────────────────────────
local function handle_get_data(client)
  local content = read_file(DATA_FILE)
  if not content then
    return json_err(client, '404 Not Found', 'Ingen data ennaa')
  end
  send_response(client, '200 OK', 'application/json', content)
end

local function handle_get_calibration(client)
  local content = read_file(CAL_FILE)
  if not content then
    return json_err(client, '404 Not Found', 'Kalibreringsfil mangler')
  end
  send_response(client, '200 OK', 'application/json', content)
end

local function handle_post_calibration(client, body)
  if body == '' then
    return json_err(client, '400 Bad Request', 'Tom body')
  end
  local ok, data = pcall(json.decode, body)
  if not ok then
    return json_err(client, '400 Bad Request', 'Ugyldig JSON')
  end
  local wrote, err = write_file(CAL_FILE, json.encode(data))
  if not wrote then
    return json_err(client, '500 Internal Server Error', err)
  end
  restart_streamer()
  logger:info('Kalibrering lagret')
  json_ok(client, { ok = true, message = 'Kalibrering lagret, streamer restartet' })
end

local function handle_get_mqtt(client)
  local content = read_file(MQTT_FILE)
  if not content then
    return json_err(client, '404 Not Found', 'MQTT-konfig mangler')
  end
  local ok, cfg = pcall(json.decode, content)
  if not ok then
    return json_err(client, '500 Internal Server Error', 'Klarte ikke lese konfig')
  end
  -- Masker passord
  cfg.password = cfg.password and cfg.password ~= '' and '********' or ''
  json_ok(client, cfg)
end

local function handle_post_mqtt(client, body)
  if body == '' then
    return json_err(client, '400 Bad Request', 'Tom body')
  end
  local ok, new_cfg = pcall(json.decode, body)
  if not ok then
    return json_err(client, '400 Bad Request', 'Ugyldig JSON')
  end
  -- Behold eksisterende passord hvis klient sender masket verdi
  if new_cfg.password == '********' or new_cfg.password == nil then
    local old = read_file(MQTT_FILE)
    if old then
      local ok2, old_cfg = pcall(json.decode, old)
      if ok2 then new_cfg.password = old_cfg.password end
    end
  end
  local wrote, err = write_file(MQTT_FILE, json.encode(new_cfg))
  if not wrote then
    return json_err(client, '500 Internal Server Error', err)
  end
  restart_streamer()
  logger:info('MQTT-konfig lagret')
  json_ok(client, { ok = true, message = 'MQTT-konfig lagret, streamer restartet' })
end

local function handle_get_status(client)
  -- Data age
  local data_age = nil
  local content = read_file(DATA_FILE)
  if content then
    local ok, d = pcall(json.decode, content)
    if ok and d.t then data_age = os.time() - d.t end
  end

  -- Uptime fra /proc/uptime
  local uptime_secs = nil
  local f = io.open('/proc/uptime', 'r')
  if f then
    local line = f:read('*l') or ''
    f:close()
    uptime_secs = tonumber(line:match('^([%d.]+)'))
  end

  -- Minne fra /proc/meminfo
  local mem_total, mem_free, mem_avail = nil, nil, nil
  f = io.open('/proc/meminfo', 'r')
  if f then
    for line in f:lines() do
      local k, v = line:match('^(%S+):%s+(%d+)')
      if     k == 'MemTotal'     then mem_total = tonumber(v)
      elseif k == 'MemFree'      then mem_free  = tonumber(v)
      elseif k == 'MemAvailable' then mem_avail = tonumber(v)
      end
    end
    f:close()
  end

  -- CPU-last fra /proc/loadavg
  local load1, load5, load15 = nil, nil, nil
  f = io.open('/proc/loadavg', 'r')
  if f then
    local line = f:read('*l') or ''
    f:close()
    load1, load5, load15 = line:match('^([%d.]+)%s+([%d.]+)%s+([%d.]+)')
    load1 = tonumber(load1); load5 = tonumber(load5); load15 = tonumber(load15)
  end

  json_ok(client, {
    uptime_secs      = uptime_secs,
    data_age_secs    = data_age,
    streamer_running = proc_running(STREAMER),
    sampler_running  = proc_running('sampler.lua'),
    mem_total_kb     = mem_total,
    mem_free_kb      = mem_free,
    mem_avail_kb     = mem_avail or mem_free,
    load_1m          = load1,
    load_5m          = load5,
    load_15m         = load15,
    web_version      = WEB_VERSION,
    lua_version      = jit and jit.version or _VERSION,
  })
end

-- ── Router ────────────────────────────────────────────────────────────────────
local routes = {
  ['GET /api/data']         = handle_get_data,
  ['GET /api/calibration']  = handle_get_calibration,
  ['POST /api/calibration'] = function(c, req) handle_post_calibration(c, req.body) end,
  ['GET /api/mqtt']         = handle_get_mqtt,
  ['POST /api/mqtt']        = function(c, req) handle_post_mqtt(c, req.body) end,
  ['GET /api/status']       = handle_get_status,
}

local function handle(client)
  local req = parse_request(client)
  if not req then client:close(); return end

  local key = req.method .. ' ' .. req.path

  -- OPTIONS preflight (CORS)
  if req.method == 'OPTIONS' then
    send_response(client, '204 No Content', 'text/plain', '')
    client:close()
    return
  end

  local handler = routes[key]
  if handler then
    local ok, err = pcall(handler, client, req)
    if not ok then
      logger:error('Handler feil [%s]: %s', key, tostring(err))
      pcall(json_err, client, '500 Internal Server Error', 'Intern feil')
    end
  else
    json_err(client, '404 Not Found', 'Ukjent endepunkt: ' .. key)
  end

  client:close()
end

-- ── Hovedloekke ───────────────────────────────────────────────────────────────
local server = assert(socket.bind('0.0.0.0', 8080))
server:settimeout(1)
logger:info('Lytter paa port 8080')

while true do
  local client, err = server:accept()
  if client then
    handle(client)
  end
end
