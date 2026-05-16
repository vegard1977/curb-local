#!/usr/bin/env lua
-- api-server.lua  v1.3
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
--   POST /api/upload         Last opp fil (HTML, bilder, Lua) -- maks 512 KB

io.stdout:setvbuf('no')
io.stderr:setvbuf('no')

local socket  = require('socket')
local json    = require('json')
local logging = require('logging')
local fileLog = require('logging.rolling_file')

local logger = fileLog('/var/log/api-server.log', 256 * 1024, 2)
logger:setLevel(logging.INFO)
logger:info('api-server v1.3 starting on port 8080')

-- ?????? Filer ???????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
local WEB_VERSION   = 'v1.2'
local MAX_UPLOAD    = 512 * 1024   -- 512 KB maks

-- Tillatte filendelser og maldirektorier for opplasting
local UPLOAD_DIRS = {
  html = '/data/sd/www/',
  png  = '/data/sd/www/',
  jpg  = '/data/sd/www/',
  jpeg = '/data/sd/www/',
  gif  = '/data/sd/www/',
  lua  = '/data/lamarr/',
}
local CAL_FILE    = '/data/calibration.json'
local MQTT_FILE   = '/data/mqtt-config.json'
local DATA_FILE   = '/tmp/www/latest.json'
local STREAMER    = 'mqtt-streamer.lua'
local HISTORY_DATA  = '/data/history.json'
local CIRCUIT_NAMES = '/data/circuit-names.json'
local DAILY_JSON    = '/data/daily.json'
local USB_DEV       = '/dev/sda1'
local USB_MOUNT     = '/mnt/usb'
local USB_AUTOMOUNT = '/etc/init.d/S50usb-mount'
local WIFI_IFACE    = 'wlan0'
local WPA_CONF      = '/etc/wpa_supplicant.conf'
local WIFI_AUTOSTART = '/etc/init.d/S51wifi'

-- Kernel-modul konfig
local MOD_USB   = '/lib/modules/3.16.0-karo/kernel/drivers/usb'
local MOD_EXTRA = '/lib/modules/3.16.0-karo/extra'
local MOD_CONF  = '/etc/curb-modules.conf'
local MAX_KO    = 1024 * 1024          -- 1 MB maks for .ko-filer
local ELF_MAGIC = string.char(127) .. 'ELF'

-- ── CLI exec ───────────────────────────────────────────────────────────────────
local CLI_TIMEOUT = 10          -- sekunder (busybox timeout)
local CLI_OUT_CAP = 64 * 1024  -- 64 KB maks per kanal

local CLI_SAFE = {
  ls=1, dir=1, cat=1, head=1, tail=1, wc=1, du=1, df=1, stat=1,
  find=1, grep=1, egrep=1, fgrep=1, awk=1, sed=1, sort=1, uniq=1,
  cut=1, tr=1, strings=1, od=1, hexdump=1, xxd=1, base64=1, diff=1,
  cmp=1, md5sum=1, sha1sum=1, sha256sum=1, cksum=1,
  ps=1, pgrep=1, uptime=1, top=1, vmstat=1, iostat=1, dstat=1,
  uname=1, hostname=1, date=1, id=1, whoami=1, env=1, printenv=1,
  lsmod=1, dmesg=1, logread=1, free=1,
  ifconfig=1, ip=1, netstat=1, ss=1, route=1, arp=1,
  ping=1, traceroute=1, tracepath=1, nslookup=1, dig=1,
  lsusb=1, lspci=1, mount=1, lsof=1,
  echo=1, printf=1, which=1, readlink=1, realpath=1, pwd=1,
  lua=1, luajit=1, wget=1, curl=1, tar=1, gzip=1, gunzip=1, zcat=1,
  file=1,
}

local CLI_DANGER = {
  rm=1, rmdir=1, kill=1, killall=1, pkill=1,
  chmod=1, chown=1, chgrp=1, reboot=1, shutdown=1, halt=1, poweroff=1,
  init=1, dd=1, mkfs=1, fsck=1, fdisk=1, parted=1,
  insmod=1, rmmod=1, modprobe=1, cp=1, mv=1, passwd=1,
  iptables=1, ip6tables=1, sysctl=1, crontab=1,
}

local CLI_META_PAT = '[;&|`$><%(%)%{%}%\\!\n\r]'

-- ?????? Hjelpere ??????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
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

-- ?????? USB hjelpere ??????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
local function shell_ok(cmd)
  local p = io.popen(cmd .. ' 2>/dev/null && echo __OK__')
  if not p then return false end
  local r = p:read('*all') or ''
  p:close()
  return r:find('__OK__', 1, true) ~= nil
end

local function shell_read(cmd)
  local p = io.popen(cmd .. ' 2>/dev/null')
  if not p then return '' end
  local r = p:read('*all') or ''
  p:close()
  return r:match('^%s*(.-)%s*$')
end

local function is_mounted(path)
  local f = io.open('/proc/mounts', 'r')
  if not f then return false end
  for line in f:lines() do
    if line:find(path, 1, true) then f:close(); return true end
  end
  f:close()
  return false
end

local function file_exists(path)
  local f = io.open(path, 'r'); if f then f:close() end; return f ~= nil
end
local function is_block_dev(path) return shell_ok('test -b ' .. path) end
local function is_symlink(path)   return shell_ok('test -L ' .. path) end

-- Sjekker om backup-mapper fremdeles ligger i /data/ (ikke migrert)
local function has_data_backups()
  local p = io.popen('ls -d /data/backup-* 2>/dev/null | head -1')
  if not p then return false end
  local r = p:read('*all') or ''; p:close()
  return r:match('%S') ~= nil
end

-- Finner f??rste tilgjengelige USB-blokkenhet: foretrekker /dev/sdX1 (partisjon),
-- faller tilbake til /dev/sdX (hel disk uten partisjonstabell)
local function find_usb_dev()
  -- Finn første tilgjengelige USB-blokk-enhet (sda, sdb, sdc...)
  -- Prøv partisjon (sdX1) først, så hele enheten (sdX)
  local blk = io.popen("ls /sys/block/ 2>/dev/null")
  if not blk then return nil end
  local devs = {}
  for dev in blk:lines() do
    if dev:match("^sd[a-z]$") then table.insert(devs, dev) end
  end
  blk:close()
  table.sort(devs)
  for _, dev in ipairs(devs) do
    if is_block_dev("/dev/" .. dev .. "1") then return "/dev/" .. dev .. "1" end
    if is_block_dev("/dev/" .. dev) then return "/dev/" .. dev end
  end
  return nil
end

local USB_AUTOMOUNT_CONTENT = [[#!/bin/sh
# S50usb-mount -- auto-monterer USB-minnepinne
# Generert av Curb web-grensesnitt
case "$1" in
  start)
    modprobe usb-storage 2>/dev/null; modprobe sd_mod 2>/dev/null
    i=0; while [ $i -lt 10 ] && ! test -b /dev/sda1; do sleep 1; i=$((i+1)); done
    test -b /dev/sda1 && mkdir -p /mnt/usb && mount /dev/sda1 /mnt/usb 2>/dev/null
    ;;
  stop) umount /mnt/usb 2>/dev/null ;;
  *) echo "Usage: $0 {start|stop}"; exit 1 ;;
esac
]]

-- ?????? HTTP hjelpere ???????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
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

-- ?????? Request parser ????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
local function parse_request(client)
  client:settimeout(2)
  local line, err = client:receive('*l')
  if not line then return nil end

  local method, path = line:match('^(%u+) ([^ ]+)')
  if not method then return nil end

  -- Headers
  local content_length = 0
  local content_type   = nil
  while true do
    line = client:receive('*l')
    if not line or line == '' or line == '\r' then break end
    local k, v = line:match('^([^:]+):%s*(.-)%s*$')
    if k then
      local kl = k:lower()
      if kl == 'content-length' then
        content_length = tonumber(v) or 0
      elseif kl == 'content-type' then
        content_type = v
      end
    end
  end

  -- Body (lenger timeout for store opplastinger)
  local body = ''
  if content_length > 0 then
    if content_length > 4096 then client:settimeout(30) end
    body = client:receive(content_length) or ''
    client:settimeout(2)
  end

  return { method = method, path = path, body = body, content_type = content_type }
end

-- ?????? Fil-opplasting hjelpere ?????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????

-- Renser filnavn: fjerner stikomponenter, tillater kun trygge tegn
local function safe_basename(name)
  local base = (name or ''):match('[^/\\]+$') or ''
  base = base:gsub('[^%w%.%-]', '')   -- kun bokstaver, tall, punkt, bindestrek
  if base == '' or base:sub(1,1) == '.' then return nil end
  return base
end

-- Parser multipart/form-data og returnerer (filnavn, data) eller (nil, nil, feilmelding)
local function parse_multipart(body, boundary)
  local sep = '--' .. boundary
  -- Finn start av forste del
  local s = body:find(sep, 1, true)
  if not s then return nil, nil, 'Ingen boundary funnet' end

  local hdr_start = s + #sep + 2   -- hopp over boundary + CRLF

  -- Finn slutten av headers (dobbel CRLF)
  local hdr_end = body:find('\r\n\r\n', hdr_start, true)
  if not hdr_end then return nil, nil, 'Ingen header-slutt' end

  local headers  = body:sub(hdr_start, hdr_end - 1)
  local filename = headers:match('filename="([^"]+)"')
  if not filename then return nil, nil, 'Ingen filename i Content-Disposition' end

  local data_start = hdr_end + 4   -- hopp over \r\n\r\n

  -- Finn avsluttende boundary
  local close_pat = '\r\n' .. sep .. '--'
  local data_end  = body:find(close_pat, data_start, true)
  if not data_end then
    -- Pr??v uten ledende CRLF (noen nettlesere)
    data_end = body:find(sep .. '--', data_start, true)
    if not data_end then return nil, nil, 'Ingen avsluttende boundary' end
  end

  return filename, body:sub(data_start, data_end - 1)
end

local function handle_post_upload(client, req)
  -- St??rrelsessjekk
  if #req.body > MAX_UPLOAD then
    return json_err(client, '413 Request Entity Too Large',
      'Maks filstorrelse er ' .. math.floor(MAX_UPLOAD / 1024) .. ' KB')
  end

  -- Hent boundary fra Content-Type
  local ct = req.content_type or ''
  local boundary = ct:match('boundary=([^;%s]+)')
  if not boundary then
    return json_err(client, '400 Bad Request', 'Mangler multipart boundary')
  end
  boundary = boundary:gsub('"', '')   -- fjern eventuelle anf.tegn

  -- Parse multipart
  local filename, data, perr = parse_multipart(req.body, boundary)
  if not filename then
    return json_err(client, '400 Bad Request', 'Multipart-feil: ' .. (perr or ''))
  end

  -- Valider filnavn
  local safe = safe_basename(filename)
  if not safe then
    return json_err(client, '400 Bad Request', 'Ugyldig filnavn: ' .. filename)
  end

  -- Hent og sjekk filendelse
  local ext = safe:match('%.([%a]+)$')
  if not ext then
    return json_err(client, '400 Bad Request', 'Filnavn mangler endelse')
  end
  ext = ext:lower()

  local dir = UPLOAD_DIRS[ext]
  if not dir then
    return json_err(client, '400 Bad Request',
      'Filtype ikke tillatt: .' .. ext ..
      ' (tillatt: html, png, jpg, jpeg, gif, lua)')
  end

  -- Lua: kun tillatte filer for sikkerhets skyld
  if ext == 'lua' then
    if safe ~= 'mqtt-streamer.lua' and safe ~= 'api-server.lua' then
      return json_err(client, '400 Bad Request',
        'Lua: kun mqtt-streamer.lua og api-server.lua er tillatt')
    end
  end

  -- Skriv filen
  local dest = dir .. safe
  local ok, werr = write_file(dest, data)
  if not ok then
    return json_err(client, '500 Internal Server Error',
      'Kunne ikke skrive fil: ' .. (werr or dest))
  end

  -- Webfiler: kopier ogs?? til aktiv /tmp/www/ slik at endringen er umiddelbar
  if dir == '/data/sd/www/' then
    write_file('/tmp/www/' .. safe, data)
  end

  -- Lua streamer: restart slik at ny versjon lastes
  local restarted = false
  if safe == 'mqtt-streamer.lua' then
    restart_streamer()
    restarted = true
  end

  logger:info('Fil lastet opp: %s (%d bytes)', dest, #data)
  json_ok(client, {
    ok       = true,
    file     = safe,
    bytes    = #data,
    path     = dest,
    restarted = restarted,
  })
end

-- ?????? Route handlers ????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
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

-- ?????? USB handlers ???????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
local function handle_get_usb_status(client)
  local dev_present = find_usb_dev() ~= nil
  local mounted     = is_mounted(USB_MOUNT)
  local automount   = file_exists(USB_AUTOMOUNT)
  local total_kb, used_kb, free_kb = 0, 0, 0
  if mounted then
    local df = shell_read('df -k ' .. USB_MOUNT .. ' | tail -1')
    local _, tot, used, avail = df:match('^(%S+)%s+(%d+)%s+(%d+)%s+(%d+)')
    total_kb = tonumber(tot) or 0; used_kb = tonumber(used) or 0; free_kb = tonumber(avail) or 0
  end
  -- Finn alle USB-blokk-enheter (sd*)
  local usb_devices = {}
  local blk = io.popen('ls /sys/block/ 2>/dev/null')
  if blk then
    for dev in blk:lines() do
      if dev:match('^sd') then
        local model   = shell_read('cat /sys/block/' .. dev .. '/device/model')
        local sectors = tonumber(shell_read('cat /sys/block/' .. dev .. '/size')) or 0
        local size_gb = math.floor(sectors * 512 / 1024 / 1024 / 102.4 + 0.5) / 10
        local part    = '/dev/' .. dev .. '1'
        local node    = is_block_dev(part) and part or '/dev/' .. dev
        table.insert(usb_devices, {
          dev   = node,
          model = model ~= '' and model or 'Ukjent',
          size_gb = size_gb,
        })
      end
    end
    blk:close()
  end

  json_ok(client, {
    device_present = dev_present, mounted = mounted, automount = automount,
    total_kb = total_kb, used_kb = used_kb, free_kb = free_kb,
    usb_devices = usb_devices,
    migrations = {
      history       = is_symlink(HISTORY_DATA),
      circuit_names = is_symlink(CIRCUIT_NAMES),
      daily         = is_symlink(DAILY_JSON),
      backups       = not has_data_backups(),
    },
  })
end

local function handle_post_usb_format(client, body)
  local ok, req = pcall(json.decode, body ~= '' and body or '{}')
  if not ok or not req.confirm then
    return json_err(client, '400 Bad Request', 'confirm:true kreves')
  end
  -- Sikkerhetsjekk: kun /dev/sd* tillatt -- aldri intern flash eller mmcblk
  local dev = req.device or ''
  if not dev:match('^/dev/sd[a-z]%d?$') then
    return json_err(client, '400 Bad Request', 'Ugyldig enhet: kun /dev/sd* er tillatt')
  end
  if not is_block_dev(dev) then
    return json_err(client, '400 Bad Request', 'Enhet ikke funnet: ' .. dev)
  end
  if is_mounted(USB_MOUNT) then os.execute('umount ' .. USB_MOUNT) end
  if not shell_ok('/sbin/mkfs.vfat -I ' .. dev) then
    return json_err(client, '500 Internal Server Error', 'Formatering feilet')
  end
  logger:info('USB formatert som FAT32: %s', dev)
  json_ok(client, { ok = true, message = 'Formatert som FAT32: ' .. dev })
end

local function handle_post_usb_mount(client)
  if is_mounted(USB_MOUNT) then
    return json_ok(client, { ok = true, message = 'Allerede montert' })
  end
  local dev = find_usb_dev()
  if not dev then
    return json_err(client, '400 Bad Request', 'Ingen USB-enhet funnet (/dev/sda eller /dev/sda1)')
  end
  os.execute('mkdir -p ' .. USB_MOUNT)
  if not shell_ok('mount ' .. dev .. ' ' .. USB_MOUNT) then
    return json_err(client, '500 Internal Server Error', 'Mount feilet')
  end
  logger:info('USB montert: %s', dev)
  json_ok(client, { ok = true, message = 'USB montert: ' .. dev })
end

local function handle_post_usb_umount(client)
  if not is_mounted(USB_MOUNT) then
    return json_ok(client, { ok = true, message = 'Ikke montert' })
  end
  if not shell_ok('umount ' .. USB_MOUNT) then
    return json_err(client, '500 Internal Server Error', 'Umount feilet (fil i bruk?)')
  end
  logger:info('USB demontert')
  json_ok(client, { ok = true, message = 'USB demontert' })
end


local function handle_post_usb_fsck(client)
  local dev = find_usb_dev()
  if not dev then
    return json_err(client, '400 Bad Request', 'Ingen USB-enhet funnet')
  end
  local was_mounted = is_mounted(USB_MOUNT)
  if was_mounted then
    if not shell_ok('umount ' .. USB_MOUNT) then
      return json_err(client, '500 Internal Server Error', 'Umount feilet (fil i bruk?)')
    end
  end
  -- fsck.vfat: -a = auto-fix, -y = svar yes på alle spørsmål
  local fp = io.popen('/sbin/fsck.vfat -a ' .. dev .. ' 2>&1; echo "EXIT:$?"', 'r')
  local output = fp:read('*a') or ''
  fp:close()
  local exit_code = tonumber(output:match('EXIT:(%d+)')) or 1
  if was_mounted then
    os.execute('mkdir -p ' .. USB_MOUNT)
    shell_ok('mount ' .. dev .. ' ' .. USB_MOUNT)
  end
  local result = output:gsub('EXIT:%d+', ''):gsub('%s+$', '')
  if exit_code == 0 then
    logger:info('fsck OK paa %s', dev)
    json_ok(client, { ok = true, message = 'Filsystem OK', output = result, exit = exit_code })
  elseif exit_code == 1 then
    logger:info('fsck fikset feil paa %s', dev)
    json_ok(client, { ok = true, message = 'Feil funnet og fikset', output = result, exit = exit_code })
  else
    json_err(client, '500 Internal Server Error', 'fsck feilet (exit ' .. exit_code .. '): ' .. result)
  end
end

local function handle_post_usb_automount(client, body)
  local ok, req = pcall(json.decode, body ~= '' and body or '{}')
  if not ok then return json_err(client, '400 Bad Request', 'Ugyldig JSON') end
  if req.enable then
    local wrote, err = write_file(USB_AUTOMOUNT, USB_AUTOMOUNT_CONTENT)
    if not wrote then
      return json_err(client, '500 Internal Server Error', 'Skriving feilet: ' .. (err or ''))
    end
    os.execute('chmod +x ' .. USB_AUTOMOUNT)
    logger:info('USB automount aktivert')
    json_ok(client, { ok = true, message = 'Automount aktivert' })
  else
    os.execute('rm -f ' .. USB_AUTOMOUNT)
    logger:info('USB automount deaktivert')
    json_ok(client, { ok = true, message = 'Automount deaktivert' })
  end
end

local function handle_post_usb_migrate(client, body)
  if not is_mounted(USB_MOUNT) then
    return json_err(client, '400 Bad Request', 'USB er ikke montert')
  end
  local ok, req = pcall(json.decode, body ~= '' and body or '{}')
  if not ok then return json_err(client, '400 Bad Request', 'Ugyldig JSON') end
  local files_map = {
    history       = { src = HISTORY_DATA,  dst = USB_MOUNT .. '/history.json' },
    circuit_names = { src = CIRCUIT_NAMES, dst = USB_MOUNT .. '/circuit-names.json' },
    daily         = { src = DAILY_JSON,    dst = USB_MOUNT .. '/daily.json' },
  }
  local results = {}
  for _, key in ipairs(req.files or {}) do
    if key == 'backups' then
      if not has_data_backups() then
        results['backups'] = 'already'
      else
        os.execute('mkdir -p ' .. USB_MOUNT .. '/backups 2>/dev/null')
        os.execute('mv /data/backup-* ' .. USB_MOUNT .. '/backups/ 2>/dev/null')
        results['backups'] = 'done'
      end
    else
      local f = files_map[key]
      if f then
        if is_symlink(f.src) then
          results[key] = 'already'
        else
          if file_exists(f.src) then
            os.execute('cp ' .. f.src .. ' ' .. f.dst)
            os.execute('rm ' .. f.src)
          else
            write_file(f.dst, '{}')
          end
          os.execute('ln -sf ' .. f.dst .. ' ' .. f.src)
          results[key] = 'done'
        end
      end
    end
  end
  logger:info('Fil-migrering ferdig')
  json_ok(client, { ok = true, results = results })
end

-- ?????? WiFi ??????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????

local WIFI_AUTOSTART_CONTENT = [[#!/bin/sh
# S51wifi -- AR9271 WiFi autostart
# Generert av Curb web-grensesnitt
case "$1" in
  start)
    modprobe ath9k_htc 2>/dev/null
    i=0; while [ $i -lt 15 ] && ! ip link show wlan0 >/dev/null 2>&1; do sleep 1; i=$((i+1)); done
    ip link set wlan0 up 2>/dev/null
    /usr/sbin/wpa_supplicant -B -D nl80211,wext -i wlan0 -c /etc/wpa_supplicant.conf 2>/dev/null
    udhcpc -i wlan0 -q -t 15 2>/dev/null
    ;;
  stop)
    killall wpa_supplicant 2>/dev/null
    killall udhcpc 2>/dev/null
    ip link set wlan0 down 2>/dev/null
    ;;
  *) echo "Usage: $0 {start|stop}"; exit 1 ;;
esac
]]

local function handle_get_wifi_status(client)
  local present = shell_ok('ip link show ' .. WIFI_IFACE)
  local up = present and shell_read('ip link show ' .. WIFI_IFACE):find('UP') ~= nil
  local ssid = up and shell_read('/sbin/iwgetid -r ' .. WIFI_IFACE .. ' 2>/dev/null') or ''
  local ip   = ''
  if up then
    local addr = shell_read('ip addr show ' .. WIFI_IFACE .. ' 2>/dev/null')
    ip = addr:match('inet (%d+%.%d+%.%d+%.%d+)') or ''
  end
  local signal_pct = 0
  if up and ssid ~= '' then
    local iw = shell_read('/sbin/iwconfig ' .. WIFI_IFACE .. ' 2>/dev/null')
    local q, qt = iw:match('Link Quality=(%d+)/(%d+)')
    if q and qt then signal_pct = math.floor(tonumber(q) / tonumber(qt) * 100) end
  end
  local module_loaded = shell_read('cat /proc/modules 2>/dev/null'):find('ath9k_htc') ~= nil
  json_ok(client, {
    present = present, up = up, ssid = ssid, ip = ip,
    signal_pct = signal_pct, module_loaded = module_loaded,
    autostart = file_exists(WIFI_AUTOSTART),
  })
end

local function handle_post_wifi_scan(client)
  if not shell_ok('ip link show ' .. WIFI_IFACE) then
    return json_err(client, '400 Bad Request', 'wlan0 ikke tilgjengelig ??? WiFi-dongle tilkoblet?')
  end
  shell_ok('ip link set ' .. WIFI_IFACE .. ' up 2>/dev/null')
  local raw = shell_read('/sbin/iwlist ' .. WIFI_IFACE .. ' scan 2>/dev/null')
  local networks, seen, cur = {}, {}, nil
  for line in (raw .. '\n'):gmatch('[^\n]+') do
    if line:find('Cell %d+') then
      if cur and cur.ssid ~= '' and not seen[cur.ssid] then
        seen[cur.ssid] = true; table.insert(networks, cur)
      end
      cur = {ssid='', signal=0, security='open'}
    elseif cur then
      local essid = line:match('ESSID:"([^"]*)"')
      if essid and essid ~= '' then cur.ssid = essid end
      local q, qt = line:match('Quality=(%d+)/(%d+)')
      if q then cur.signal = math.floor(tonumber(q) / tonumber(qt) * 100) end
      if line:find('WPA2') or line:find('RSN:') then cur.security = 'WPA2'
      elseif line:find('WPA:') or line:find('WPA ') then cur.security = 'WPA' end
    end
  end
  if cur and cur.ssid ~= '' and not seen[cur.ssid] then table.insert(networks, cur) end
  json_ok(client, {networks = networks})
end

local function handle_post_wifi_connect(client, body)
  local ok, req = pcall(json.decode, body ~= '' and body or '{}')
  if not ok or not req.ssid or req.ssid == '' then
    return json_err(client, '400 Bad Request', 'ssid kreves')
  end
  if not shell_ok('ip link show ' .. WIFI_IFACE) then
    return json_err(client, '400 Bad Request', 'wlan0 ikke tilgjengelig')
  end
  -- Fjern utrygge tegn fra SSID og passord
  local ssid = req.ssid:gsub('["%c\\]', '')
  local pw   = (req.password or ''):gsub('["%c\\]', '')
  -- Skriv wpa_supplicant.conf direkte (unng??r shell-injection via wpa_passphrase)
  local conf
  if pw ~= '' then
    conf = 'network={\n    ssid="' .. ssid .. '"\n    psk="' .. pw .. '"\n}\n'
  else
    conf = 'network={\n    ssid="' .. ssid .. '"\n    key_mgmt=NONE\n}\n'
  end
  write_file(WPA_CONF, conf)
  -- Drep eventuell eksisterende wpa_supplicant og start p?? nytt
  os.execute('killall wpa_supplicant 2>/dev/null; sleep 1')
  shell_ok('ip link set ' .. WIFI_IFACE .. ' up 2>/dev/null')
  if not shell_ok('/usr/sbin/wpa_supplicant -B -D nl80211,wext -i ' .. WIFI_IFACE .. ' -c ' .. WPA_CONF) then
    return json_err(client, '500 Internal Server Error', 'wpa_supplicant feilet ??? sjekk SSID/passord')
  end
  os.execute('udhcpc -i ' .. WIFI_IFACE .. ' -q -t 15 2>/dev/null &')
  logger:info('WiFi tilkobling startet: %s', ssid)
  json_ok(client, {ok=true, message='Kobler til ' .. ssid .. '...'})
end

local function handle_post_wifi_disconnect(client)
  os.execute('killall wpa_supplicant 2>/dev/null')
  os.execute('killall udhcpc 2>/dev/null')
  os.execute('ip addr flush dev ' .. WIFI_IFACE .. ' 2>/dev/null')
  os.execute('ip link set ' .. WIFI_IFACE .. ' down 2>/dev/null')
  logger:info('WiFi frakoblet')
  json_ok(client, {ok=true, message='WiFi frakoblet'})
end

local function handle_post_wifi_autostart(client, body)
  local ok, req = pcall(json.decode, body ~= '' and body or '{}')
  if not ok then return json_err(client, '400 Bad Request', 'Ugyldig JSON') end
  if req.enable then
    if not file_exists(WPA_CONF) then
      return json_err(client, '400 Bad Request', 'Ingen nettverkskonfig ??? koble til et nettverk f??rst')
    end
    local wrote, err = write_file(WIFI_AUTOSTART, WIFI_AUTOSTART_CONTENT)
    if not wrote then
      return json_err(client, '500 Internal Server Error', 'Skriving feilet: ' .. (err or ''))
    end
    os.execute('chmod +x ' .. WIFI_AUTOSTART)
    logger:info('WiFi autostart aktivert')
    json_ok(client, {ok=true, message='Autostart aktivert'})
  else
    os.execute('rm -f ' .. WIFI_AUTOSTART)
    logger:info('WiFi autostart deaktivert')
    json_ok(client, {ok=true, message='Autostart deaktivert'})
  end
end

-- ━━━━ Kernel-moduler ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Konverter filnavn → kernelmodul-navn  (cdc-acm.ko → cdc_acm)
local function ko_to_modname(fname)
  local stem = fname:match('^(.+)%.ko$') or fname
  return stem:gsub('%-', '_')
end

-- Hent sett av lastede modulnavn fra lsmod
local function get_loaded_set()
  local loaded = {}
  local p = io.popen('/sbin/lsmod 2>/dev/null')
  if p then
    local first = true
    for line in p:lines() do
      if first then first = false
      else
        local name = line:match('^(%S+)')
        if name then loaded[name] = true end
      end
    end
    p:close()
  end
  return loaded
end

-- Les /etc/curb-modules.conf → sett av stier
local function read_mod_conf()
  local conf = {}
  local f = io.open(MOD_CONF, 'r')
  if not f then return conf end
  for line in f:lines() do
    line = line:match('^%s*(.-)%s*$')
    if line ~= '' and line:sub(1,1) ~= '#' then
      conf[line] = true
    end
  end
  f:close()
  return conf
end

-- Skriv /etc/curb-modules.conf fra sett (sortert)
local function write_mod_conf(conf)
  local paths = {}
  for path in pairs(conf) do table.insert(paths, path) end
  table.sort(paths)
  local content = #paths > 0 and (table.concat(paths, '\n') .. '\n') or ''
  return write_file(MOD_CONF, content)
end

-- Skann kjente .ko-kataloger
local function scan_ko_files()
  local files = {}
  local dirs = {
    { path = MOD_USB .. '/class',  extra = false },
    { path = MOD_USB .. '/serial', extra = false },
    { path = MOD_EXTRA,            extra = true  },
  }
  for _, d in ipairs(dirs) do
    local p = io.popen('ls ' .. d.path .. '/*.ko 2>/dev/null')
    if p then
      for fpath in p:lines() do
        fpath = fpath:match('^%s*(.-)%s*$')
        local fname = fpath:match('[^/]+$')
        if fname and fname:match('%.ko$') then
          local size = 0
          local sf = io.open(fpath, 'rb')
          if sf then size = sf:seek('end') or 0; sf:close() end
          table.insert(files, {
            name     = fname,
            path     = fpath,
            module   = ko_to_modname(fname),
            size     = size,
            is_extra = d.extra,
          })
        end
      end
      p:close()
    end
  end
  return files
end

local function handle_get_modules(client, req)
  local loaded = get_loaded_set()
  local conf   = read_mod_conf()
  local files  = scan_ko_files()
  for _, f in ipairs(files) do
    f.loaded   = loaded[f.module] == true
    f.autoload = conf[f.path] == true
  end
  json_ok(client, { files = files })
end

local function handle_post_modules_upload(client, req)
  if #req.body > MAX_KO then
    return json_err(client, '413 Request Entity Too Large', 'Maks filstørrelse er 1 MB')
  end
  local ct = req.content_type or ''
  local boundary = ct:match('boundary=([^;%s]+)')
  if not boundary then
    return json_err(client, '400 Bad Request', 'Mangler multipart boundary')
  end
  boundary = boundary:gsub('"', '')
  local filename, data, perr = parse_multipart(req.body, boundary)
  if not filename then
    return json_err(client, '400 Bad Request', 'Multipart-feil: ' .. (perr or ''))
  end
  local safe = safe_basename(filename)
  if not safe then
    return json_err(client, '400 Bad Request', 'Ugyldig filnavn')
  end
  if not safe:match('%.ko$') then
    return json_err(client, '400 Bad Request', 'Kun .ko-filer tillatt')
  end
  -- ELF-magic sjekk (første 4 bytes = 0x7F 'E' 'L' 'F')
  if #data < 4 or data:sub(1, 4) ~= ELF_MAGIC then
    return json_err(client, '400 Bad Request', 'Ikke en gyldig ELF-fil (mangler ELF-magic)')
  end
  -- Vermagic-sjekk: søk etter karo-kernel-streng i binæren
  if not data:find('3.16.0-karo', 1, true) then
    return json_err(client, '400 Bad Request',
      'Feil vermagic – modulen er ikke bygd for kernel 3.16.0-karo')
  end
  os.execute('mkdir -p ' .. MOD_EXTRA)
  local dest = MOD_EXTRA .. '/' .. safe
  local wf, werr = io.open(dest, 'wb')
  if not wf then
    return json_err(client, '500 Internal Server Error', 'Skriving feilet: ' .. (werr or ''))
  end
  wf:write(data); wf:close()
  os.execute('chmod 644 ' .. dest)
  logger:info('Modul lastet opp: %s (%d bytes) → %s', safe, #data, dest)
  json_ok(client, { ok=true, message='Lagret: ' .. safe, path=dest, size=#data })
end

local function handle_post_modules_load(client, req)
  local ok_j, body = pcall(json.decode, req.body ~= '' and req.body or '{}')
  if not ok_j or type(body) ~= 'table' then
    return json_err(client, '400 Bad Request', 'Ugyldig JSON')
  end
  local path = body.path
  if type(path) ~= 'string' or path == '' then
    return json_err(client, '400 Bad Request', 'Mangler "path"')
  end
  local ok_path = false
  for _, pfx in ipairs({'/lib/modules/3.16.0-karo/', '/data/sd/'}) do
    if path:sub(1, #pfx) == pfx then ok_path = true; break end
  end
  if not ok_path or path:find('%.%.') then
    return json_err(client, '403 Forbidden', 'Ikke tillatt sti')
  end
  if not file_exists(path) then
    return json_err(client, '404 Not Found', 'Fil ikke funnet: ' .. path)
  end
  local p = io.popen('/sbin/insmod ' .. path .. ' 2>&1; echo __EXIT__$?')
  local out = p and p:read('*all') or ''
  if p then p:close() end
  local code = tonumber(out:match('__EXIT__(%d+)')) or 1
  local msg  = out:gsub('__EXIT__%d+%s*', ''):match('^%s*(.-)%s*$') or ''
  if code == 0 then
    logger:info('insmod OK: %s', path)
    json_ok(client, { ok=true, message='Lastet: ' .. (path:match('[^/]+$') or path) })
  else
    local hint = (msg:find('already') or msg:find('exists')) and ' (allerede lastet)' or ''
    logger:warn('insmod feilet [%s]: %s', path, msg)
    json_err(client, '500 Internal Server Error',
      'insmod feilet' .. hint .. (msg ~= '' and (': ' .. msg) or ''))
  end
end

local function handle_post_modules_unload(client, req)
  local ok_j, body = pcall(json.decode, req.body ~= '' and req.body or '{}')
  if not ok_j or type(body) ~= 'table' then
    return json_err(client, '400 Bad Request', 'Ugyldig JSON')
  end
  local modname = body.module
  if type(modname) ~= 'string' or modname == '' then
    return json_err(client, '400 Bad Request', 'Mangler "module"')
  end
  if not modname:match('^[%w_]+$') then
    return json_err(client, '400 Bad Request', 'Ugyldig modulnavn')
  end
  local p = io.popen('/sbin/rmmod ' .. modname .. ' 2>&1; echo __EXIT__$?')
  local out = p and p:read('*all') or ''
  if p then p:close() end
  local code = tonumber(out:match('__EXIT__(%d+)')) or 1
  local msg  = out:gsub('__EXIT__%d+%s*', ''):match('^%s*(.-)%s*$') or ''
  if code == 0 then
    logger:info('rmmod OK: %s', modname)
    json_ok(client, { ok=true, message='Avlastet: ' .. modname })
  else
    local hint = msg:find('not loaded') and ' (ikke lastet)' or
                 (msg:find('in use') and ' (i bruk)' or '')
    logger:warn('rmmod feilet [%s]: %s', modname, msg)
    json_err(client, '500 Internal Server Error',
      'rmmod feilet' .. hint .. (msg ~= '' and (': ' .. msg) or ''))
  end
end

local function handle_post_modules_autoload(client, req)
  local ok_j, body = pcall(json.decode, req.body ~= '' and req.body or '{}')
  if not ok_j or type(body) ~= 'table' then
    return json_err(client, '400 Bad Request', 'Ugyldig JSON')
  end
  local path   = body.path
  local enable = body.enable
  if type(path) ~= 'string' or path == '' then
    return json_err(client, '400 Bad Request', 'Mangler "path"')
  end
  local ok_path = false
  for _, pfx in ipairs({'/lib/modules/3.16.0-karo/', '/data/sd/'}) do
    if path:sub(1, #pfx) == pfx then ok_path = true; break end
  end
  if not ok_path or path:find('%.%.') then
    return json_err(client, '403 Forbidden', 'Ikke tillatt sti')
  end
  local conf = read_mod_conf()
  if enable then conf[path] = true else conf[path] = nil end
  local wrote, werr = write_mod_conf(conf)
  if not wrote then
    return json_err(client, '500 Internal Server Error', 'Skriving feilet: ' .. (werr or ''))
  end
  local fname  = path:match('[^/]+$') or path
  local action = enable and 'aktivert' or 'deaktivert'
  logger:info('Autoload %s: %s', action, path)
  json_ok(client, { ok=true, message='Autoload ' .. action .. ': ' .. fname })
end

local function handle_post_modules_delete(client, req)
  local ok_j, body = pcall(json.decode, req.body ~= '' and req.body or '{}')
  if not ok_j or type(body) ~= 'table' then
    return json_err(client, '400 Bad Request', 'Ugyldig JSON')
  end
  local path = body.path
  if type(path) ~= 'string' or path == '' then
    return json_err(client, '400 Bad Request', 'Mangler "path"')
  end
  local pfx = MOD_EXTRA .. '/'
  if path:sub(1, #pfx) ~= pfx or path:find('%.%.') then
    return json_err(client, '403 Forbidden', 'Kan kun slette filer fra ' .. MOD_EXTRA)
  end
  if not file_exists(path) then
    return json_err(client, '404 Not Found', 'Fil ikke funnet')
  end
  local conf = read_mod_conf()
  conf[path] = nil
  write_mod_conf(conf)
  if not shell_ok('rm -f ' .. path) then
    return json_err(client, '500 Internal Server Error', 'Sletting feilet')
  end
  logger:info('Modul slettet: %s', path)
  json_ok(client, { ok=true, message='Slettet: ' .. (path:match('[^/]+$') or path) })
end

-- ── CLI exec handler ──────────────────────────────────────────────────────────
local CLI_COUNTER = 0
local CLI_CWD     = '/root'   -- arbeidsmappe, delt mellom alle requests (single-user)
local CLI_CWD_OLD = '/root'   -- for "cd -"

local function handle_post_cli_exec(client, req)
  local ok, data = pcall(json.decode, req.body or '')
  if not ok or type(data) ~= 'table' then
    return json_err(client, '400 Bad Request', 'Ugyldig JSON')
  end

  local cmd = data.cmd
  if type(cmd) ~= 'string' or cmd:match('^%s*$') then
    return json_err(client, '400 Bad Request', 'Tom kommando')
  end
  cmd = cmd:match('^%s*(.-)%s*$')

  -- ── cd er eit shell-builtin; handter det separat ───────────────────────────
  local cd_arg = cmd:match('^cd%s+(.+)$')
  local is_cd  = (cmd == 'cd') or (cd_arg ~= nil)

  if is_cd then
    local target
    if cmd == 'cd' then
      target = '/root'
    elseif cd_arg == '-' then
      target = CLI_CWD_OLD
    else
      target = cd_arg
    end
    local sq_cwd = CLI_CWD:gsub("'", "'\\''")
    local sq_tgt = target:gsub("'", "'\\''")
    local p = io.popen(string.format("cd '%s' && cd '%s' && pwd 2>&1", sq_cwd, sq_tgt), 'r')
    local out = (p and p:read('*all') or ''):match('^%s*(.-)%s*$')
    if p then p:close() end
    if out and out:sub(1,1) == '/' then
      CLI_CWD_OLD = CLI_CWD
      CLI_CWD     = out
      return json_ok(client, { stdout='', stderr='', exit_code=0, duration_ms=0, cwd=CLI_CWD })
    else
      return json_ok(client, {
        stdout='', stderr='cd: ' .. target .. ': No such file or directory',
        exit_code=1, duration_ms=0, cwd=CLI_CWD,
      })
    end
  end

  local prog_full = cmd:match('^([^%s]+)') or ''
  local prog = prog_full:match('[^/]+$') or prog_full

  local is_safe   = CLI_SAFE[prog]   ~= nil
  local is_danger = CLI_DANGER[prog] ~= nil
  local has_meta  = cmd:find(CLI_META_PAT) ~= nil
  local confirmed = data.confirmed == true

  local need_confirm = false
  local confirm_msg  = ''

  if is_danger then
    need_confirm = true
    confirm_msg  = prog .. ' er en farlig kommando'
  elseif is_safe and has_meta then
    need_confirm = true
    confirm_msg  = 'Kommandoen inneholder shell-tegn'
  elseif not is_safe and not is_danger then
    need_confirm = true
    confirm_msg  = 'Ukjent kommando: ' .. prog
  end

  if need_confirm and not confirmed then
    return json_ok(client, {
      requires_confirm = true,
      message          = confirm_msg .. ' — bekreft for å kjøre',
      cwd              = CLI_CWD,
    })
  end

  local t0 = socket.gettime()
  CLI_COUNTER = CLI_COUNTER + 1
  local tmp_err = string.format('/tmp/cli_err_%d_%d', os.time(), CLI_COUNTER)

  -- Prefix alle kommandoar med cd til gjeldande arbeidsmappe
  local sq_cwd = CLI_CWD:gsub("'", "'\\''")
  local sq     = cmd:gsub("'", "'\\''")
  local sh = string.format(
    "cd '%s' && timeout %d sh -c '%s' 2>'%s'; printf '\\n__EXIT__%%d' $?",
    sq_cwd, CLI_TIMEOUT, sq, tmp_err)

  local p   = io.popen(sh, 'r')
  local raw = (p and p:read('*all')) or ''
  if p then p:close() end

  local t1 = socket.gettime()

  local stdout, exit_str = raw:match('^(.-)[\r\n]*__EXIT__(%d+)%s*$')
  if not stdout then stdout = raw; exit_str = '0' end
  local exit_code = tonumber(exit_str) or 0

  local stderr = read_file(tmp_err) or ''
  os.execute("rm -f '" .. tmp_err .. "'")

  if exit_code == 124 or exit_code == 143 then
    stdout = stdout .. '\n[Timeout: avbrutt etter ' .. CLI_TIMEOUT .. 's]'
  end
  if #stdout > CLI_OUT_CAP then
    stdout = stdout:sub(1, CLI_OUT_CAP) .. '\n[avkuttet — maks ' .. (CLI_OUT_CAP/1024) .. ' KB]'
  end
  if #stderr > CLI_OUT_CAP then
    stderr = stderr:sub(1, CLI_OUT_CAP) .. '\n[avkuttet]'
  end

  local duration_ms = math.floor((t1 - t0) * 1000)
  logger:info('cli exec: %s (exit=%d, %dms, out=%d err=%d)',
    prog, exit_code, duration_ms, #stdout, #stderr)

  json_ok(client, {
    stdout      = stdout,
    stderr      = stderr,
    exit_code   = exit_code,
    duration_ms = duration_ms,
    cwd         = CLI_CWD,
  })
end

-- ── CLI complete handler ───────────────────────────────────────────────────────
local function handle_post_cli_complete(client, req)
  local ok, data = pcall(json.decode, req.body or '')
  if not ok or type(data) ~= 'table' then
    return json_ok(client, { completions = {}, cwd = CLI_CWD })
  end

  local partial = data.partial
  if type(partial) ~= 'string' or partial == '' then
    return json_ok(client, { completions = {}, cwd = CLI_CWD })
  end

  local sq_cwd  = CLI_CWD:gsub("'", "'\\''")
  local sq_part = partial:gsub("'", "'\\''")

  -- ls -dp: lister matching entries; -p legg til / for mapper; -d viser ikkje innhald
  local sh = string.format("cd '%s' && ls -dp -- '%s'* 2>/dev/null", sq_cwd, sq_part)
  local p   = io.popen(sh, 'r')
  local out = (p and p:read('*all')) or ''
  if p then p:close() end

  local completions = {}
  local count = 0
  for line in out:gmatch('[^\n]+') do
    if count >= 50 then break end
    table.insert(completions, line)
    count = count + 1
  end

  json_ok(client, { completions = completions, cwd = CLI_CWD })
end

-- ?????? Router ????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
local routes = {
  ['GET /api/data']         = handle_get_data,
  ['GET /api/calibration']  = handle_get_calibration,
  ['POST /api/calibration'] = function(c, req) handle_post_calibration(c, req.body) end,
  ['GET /api/mqtt']         = handle_get_mqtt,
  ['POST /api/mqtt']        = function(c, req) handle_post_mqtt(c, req.body) end,
  ['GET /api/status']       = handle_get_status,
  ['POST /api/upload']      = handle_post_upload,
  ['GET /api/usb/status']     = handle_get_usb_status,
  ['POST /api/usb/format']    = function(c, req) handle_post_usb_format(c, req.body) end,
  ['POST /api/usb/mount']     = function(c, req) handle_post_usb_mount(c) end,
  ['POST /api/usb/umount']    = function(c, req) handle_post_usb_umount(c) end,
  ['POST /api/usb/fsck']      = function(c, req) handle_post_usb_fsck(c) end,
  ['POST /api/usb/automount'] = function(c, req) handle_post_usb_automount(c, req.body) end,
  ['POST /api/usb/migrate']   = function(c, req) handle_post_usb_migrate(c, req.body) end,
  ['GET /api/wifi/status']      = handle_get_wifi_status,
  ['POST /api/wifi/scan']       = function(c, req) handle_post_wifi_scan(c) end,
  ['POST /api/wifi/connect']    = function(c, req) handle_post_wifi_connect(c, req.body) end,
  ['POST /api/wifi/disconnect'] = function(c, req) handle_post_wifi_disconnect(c) end,
  ['POST /api/wifi/autostart']  = function(c, req) handle_post_wifi_autostart(c, req.body) end,
  ['GET /api/modules/status']    = handle_get_modules,
  ['POST /api/modules/upload']   = handle_post_modules_upload,
  ['POST /api/modules/load']     = handle_post_modules_load,
  ['POST /api/modules/unload']   = handle_post_modules_unload,
  ['POST /api/modules/autoload'] = handle_post_modules_autoload,
  ['POST /api/modules/delete']   = handle_post_modules_delete,
  ['POST /api/cli/exec']         = handle_post_cli_exec,
  ['POST /api/cli/complete']     = handle_post_cli_complete,
}

local function handle(client)
  local req = parse_request(client)
  if not req then client:close(); return end

  local clean_path = req.path:match('^([^?]+)') or req.path
  local key = req.method .. ' ' .. clean_path

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

-- ?????? Hovedloekke ?????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
local server = assert(socket.bind('0.0.0.0', 8080))
server:settimeout(1)
logger:info('Lytter paa port 8080')

while true do
  local client, err = server:accept()
  if client then
    handle(client)
  end
end

