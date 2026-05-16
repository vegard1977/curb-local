# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [v2.0] — 2026-05-16

### Added
- **Web terminal** (`cli.html`) — full SSH-like terminal in the browser with Tab-completion, command history (↑/↓), ANSI colour output and live output streaming via `api-server.lua`
- **Arduino / Serial monitor** (`arduino.html`) — live serial monitor for Arduino Mega, Uno, ESP32 and other USB-serial devices; auto-detects ports, configurable baud rate, send commands
- **Serial reader** (`serial-reader.lua`) — multi-device serial reader using `select()` for non-blocking parallel reads; device list managed via `/data/serial-devices.json`
- **Live measurement list** (`kursliste.html`) — per-circuit live W/A/V/PF table with sortable columns, group totals and one-click PDF print
- **Kernel module manager** (`modules.html`) — browse, load and unload USB kernel modules from the browser; shows loaded/unloaded state, module info and boot-persistence toggle
- **USB file manager** (`usb.html`) — browse `/data/sd/` from the browser: upload, download, rename, delete files; format USB partition; move/copy files between directories
- **WiFi configuration** (`wifi.html`) — scan for access points, connect/disconnect, show signal strength and current connection state
- **USB kernel drivers** (`modules/bin/`) — pre-compiled kernel modules for Linux 3.16.0-karo: `cdc-acm` (Arduino Uno/Mega, ESP32 native USB), `ch341` (CH340G clones), `cp210x` (Silicon Labs CP2102), `usbserial` core and `usb-storage`
- **Kernel module init scripts** (`modules/init/`) — `S35modules` (config-driven, managed by modules.html) and `S35cdc-modules` (fixed cdc/ch341/cp210x loader); `curb-modules.conf` template for boot persistence
- **Arduino PlatformIO project** (`arduino/`) — `main.cpp` forwards Curb energy data over USB serial to connected Arduino/ESP32
- `serial-devices.json.example` — example config for serial-reader device list

### Changed
- `install.sh` — deploys all 12 web pages, `serial-reader.lua`, and `serial-devices.json`; adds `serial reader` to `hm.conf`; patches `curb_status.sh` for all new pages
- All pages updated to v2.0 in footer

---

## [v1.3] — 2026-04-27

### Added
- **File upload via browser** (`settings.html`) — drag-and-drop or click to upload HTML pages, images (png/jpg/gif) or Lua scripts directly to the Curb device, no SSH required
- `api-server.lua` v1.3: `POST /api/upload` endpoint with multipart/form-data parser, filename sanitization, extension whitelist, 512 KB limit
- Auto-restart of `mqtt-streamer.lua` when a new streamer version is uploaded

### Fixed
- GitHub repository URL corrected to `vegard1977/curb-local` in all pages and CHANGELOG (was `vegardm`)
- Version update check now points to the correct repository

---

## [v1.2] — 2026-04-27

### Added
- **Statistics page** (`stats.html`) — daily kWh donut charts per CT group, hourly bar chart, period selector (Day / Week / Month / Year)
- **Historical archive** — `history.json` stores per-circuit kWh per day (max 365 days), archived at midnight
- **Serial & Powerline guide** (`serial-guide.html`) — J6 debug port pinout, USB-serial wiring instructions, PLC pairing guide with photos
- **System info improvements** — device info cards (serial, HW version, OS version, SW version), storage bars for `/data` and `/data/sd`, network section (IP, per-interface state / MAC / RX/TX / drops), PLC section (CCO MAC, TX/RX SNR dB)
- **Version update notification** — banner on all pages checks GitHub releases API and alerts when a newer version is available
- **CHANGELOG.md** — this file

### Changed
- `sysinfo.html` now fetches pre-computed `sysinfo.json` (written every 10 s by `mqtt-streamer.lua`) instead of making slow on-demand shell calls — response time down from seconds to ~18 ms
- `curb_status.sh` simplified: removed slow `plctool`/`plcstat`/`pingstats` calls; now copies all 6 HTML pages + images and creates a redirect index
- Muted text color updated to `#8b949e` across all pages for better readability

### Fixed
- Lua scoping bug: `last_sample_t` (used to detect sampler liveness) was declared after `write_sysinfo()` definition, causing `sampler_running` to always report false

---

## [v1.1] — 2026-04-24

### Added
- **System info page** (`sysinfo.html`) — uptime, memory, CPU load, process status (sampler / streamer / api-server)
- `mqtt-streamer.lua` writes `sysinfo.json` to `/tmp/www/` every 10 s
- Device info: serial number, hardware version, OS version, software version
- PLC signal quality (TX/RX SNR dB) cached every 5 minutes to avoid slow `plcstat` calls on each refresh
- Network interfaces section: state, MAC address, RX/TX traffic, drop counters

### Changed
- `install.sh` now deploys all pages including `sysinfo.html` and `serial-guide.html`
- Home Assistant MQTT discovery changed to async (non-blocking at startup)

---

## [v1.0] — 2026-04-23

### Added
- Initial release — replaces Curb Cloud dependency with a fully local solution
- **Dashboard** (`energy.html`) — live power per circuit (W / A / V / PF), group totals, distribution pie chart
- **Statistics** (`stats.html` basic) — daily kWh accumulation, hourly bar chart
- **Calibration** (`calibration.html`) — per-circuit CT scale factors, live readings, 0 A reset
- **Settings** (`settings.html`) — MQTT broker, credentials, base topic, device name — editable from browser
- `mqtt-streamer.lua` — replaces `curb-to-mqtt.py`; direct MQTT publish, kWh accumulation, `latest.json` / `daily.json` writer
- `api-server.lua` — REST API on port 8080 for web interface
- Home Assistant MQTT auto-discovery (18 circuits × 4 sensors: W, A, PF, V)
- `install.sh` — automated deployment with SSH key or sshpass support, automatic backup, log file

---

[v2.0]: https://github.com/vegard1977/curb-local/releases/tag/v2.0
[v1.3]: https://github.com/vegard1977/curb-local/releases/tag/v1.3
[v1.2]: https://github.com/vegard1977/curb-local/releases/tag/v1.2
[v1.1]: https://github.com/vegard1977/curb-local/releases/tag/v1.1
[v1.0]: https://github.com/vegard1977/curb-local/releases/tag/v1.0
