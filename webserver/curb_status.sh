#!/bin/sh
BASE_DIR="/tmp/www"
STATUS_PAGE=$BASE_DIR/index.html
STATUS_JSON=$BASE_DIR/status.json
mkdir -p "$BASE_DIR"

POST_LOG_LENGTH=200
PAGE_LOG_LENGTH=400

SED_JSON_FILTER=':a;N;$!ba;s/\n/\\\\n/g;s/"/\\"/g'
SED_HTML_FILTER='s/$/<br>/'

date=$(date)                 
serialNumber=$(/usr/local/bin/curb_serial_number.sh)             
hardwareVersion=$(/usr/local/bin/curb_eeprom hardwareVersion)       
modelNumber=$(/usr/local/bin/curb_eeprom modelNumber)
osVersion=$(cat /etc/os_version)                                    
softwareVersion=$(cat /data/software_version)
uptime=$(uptime)                                                    

free=$(free | tr '\t' '    ' | sed $SED_JSON_FILTER)
ps=$(ps -o pid,user,vsz,rss,comm,args | tr '\t' '    ' | sed $SED_JSON_FILTER)
eth0=$(ifconfig eth0 | tr '\t' '    ' | sed $SED_JSON_FILTER)
eth1=$(ifconfig eth1 | tr '\t' '    ' | sed $SED_JSON_FILTER)
wlan0=$(ifconfig wlan0 | tr '\t' '    ' | sed $SED_JSON_FILTER)
plc=$(/usr/local/bin/plctool -I | tr '\t' '    ' | sed $SED_JSON_FILTER)
plcstats=$(/usr/local/bin/plcstat -s 0xFC -d both -t -e -m | tr '\t' '    ' | sed $SED_JSON_FILTER)
pingstats=$(/usr/local/bin/pingstats.sh | tr '\t' '    ' | sed $SED_JSON_FILTER)
storage=$(df -h | tr '\t' '    ' | sed $SED_JSON_FILTER)
samplerLog=""
if [ -f /var/log/sampler.log ]; then
    samplerLog=$(tail -n $POST_LOG_LENGTH /var/log/sampler.log | sed $SED_JSON_FILTER)
fi
streamerLog=""
if [ -f /var/log/streamer.log ]; then
    streamerLog=$(tail -n $POST_LOG_LENGTH /var/log/streamer.log | sed $SED_JSON_FILTER)
fi
monitorLog=""
updateLog=""
if [ -f /var/log/messages ]; then
    monitorLog=$(grep curb_hmon /var/log/messages | tail -n $POST_LOG_LENGTH | sed $SED_JSON_FILTER)
    updateLog=$(grep curb_update /var/log/messages | tail -n 200 | sed $SED_JSON_FILTER)
fi
persistentSamplerLog=""
if [ -f /data/sd/log/sampler.log ]; then
    persistentSamplerLog=$(tail -n $POST_LOG_LENGTH /data/sd/log/sampler.log | sed $SED_JSON_FILTER)
fi
persistentStreamerLog=""
if [ -f /data/sd/log/streamer.log ]; then
    persistentStreamerLog=$(tail -n $POST_LOG_LENGTH /data/sd/log/streamer.log | sed $SED_JSON_FILTER)
fi
persistentMonitorLog=""
persistentUpdateLog=""
if [ -f /data/sd/log/messages ]; then
    persistentMonitorLog=$(grep curb_hmon /data/sd/log/messages | tail -n $POST_LOG_LENGTH | sed $SED_JSON_FILTER)
    persistentUpdateLog=$(grep curb_update /data/sd/log/messages | tail -n $POST_LOG_LENGTH | sed $SED_JSON_FILTER)
fi

# Check for rollback - if uBoot runs a rollback it adds 'rollback' to the kernel parameter list
osRollbackRunning="no"
grep -q rollback /proc/cmdline
if [ $? -eq 0 ]; then
  osRollbackRunning="yes"
fi

echo "<html>" > $STATUS_PAGE
echo "<head>" >> $STATUS_PAGE
echo "<style>td { font-family: monospace; }</style>" >> $STATUS_PAGE
echo "<title>Curb Status</title></title>" >> $STATUS_PAGE
echo "</head>" >> $STATUS_PAGE
echo "<body>" >> $STATUS_PAGE
echo "<table border=\"1\" style=\"width:100%\">" >> $STATUS_PAGE
echo "<tr><td>Date</td><td>$(date)</td></tr>" >> $STATUS_PAGE
echo "<tr><td>Serial number</td><td>$serialNumber</td></tr>" >> $STATUS_PAGE
echo "<tr><td>Hardware version</td><td>$hardwareVersion</td></tr>" >> $STATUS_PAGE
echo "<tr><td>Model number</td><td>$modelNumber</td></tr>" >> $STATUS_PAGE
echo "<tr><td>OS version</td><td>$osVersion</td></tr>" >> $STATUS_PAGE
echo "<tr><td>Software version</td><td>$softwareVersion</td></tr>" >> $STATUS_PAGE
echo "<tr><td>OS rollback running</td><td>$osRollbackRunning</td></tr>" >> $STATUS_PAGE
echo "<tr><td>Uptime</td><td>$uptime</td></tr>" >> $STATUS_PAGE
echo "<tr><td>Free</td><td>$free</td></tr>" >> $STATUS_PAGE
echo "<tr><td>Processes</td><td>$(ps -o pid,user,vsz,rss,comm,args | sed $SED_HTML_FILTER)</td></tr>" >> $STATUS_PAGE
echo "<tr><td>Network</td><td>$(ifconfig | sed $SED_HTML_FILTER)</td></tr>" >> $STATUS_PAGE
echo "<tr><td>PLC</td><td>$(/usr/local/bin/plctool -I | sed $SED_HTML_FILTER)</td></tr>" >> $STATUS_PAGE
echo "<tr><td>PLC stats</td><td>$(/usr/local/bin/plcstat -s 0xFC -d both -t -e -m | sed $SED_HTML_FILTER)</td></tr>" >> $STATUS_PAGE
echo "<tr><td>Cloud connectivity</td><td>$(/usr/local/bin/pingstats.sh | sed $SED_HTML_FILTER)</td></tr>" >> $STATUS_PAGE
echo "<tr><td>Storage</td><td>$(df -h | sed $SED_HTML_FILTER)</td></tr>" >> $STATUS_PAGE
if [ -f /var/log/sampler.log ]; then
    echo "<tr><td>Sampler log</td><td>$(tail -n $PAGE_LOG_LENGTH /var/log/sampler.log | sed $SED_HTML_FILTER)</td></tr>" >> $STATUS_PAGE
fi
if [ -f /var/log/streamer.log ]; then
    echo "<tr><td>Streamer log</td><td>$(tail -n $PAGE_LOG_LENGTH /var/log/streamer.log | sed $SED_HTML_FILTER)</td></tr>" >> $STATUS_PAGE
fi
if [ -f /var/log/messages ]; then
    echo "<tr><td>Monitor log</td><td>$(grep curb_hmon /var/log/messages | tail -n $PAGE_LOG_LENGTH | sed $SED_HTML_FILTER)</td></tr>" >> $STATUS_PAGE
    echo "<tr><td>Update log</td><td>$(grep curb_update /var/log/messages | tail -n 500 | sed $SED_HTML_FILTER)</td></tr>" >> $STATUS_PAGE
fi
if [ -f /data/sd/log/sampler.log ]; then
    echo "<tr><td>Persistent sampler log</td><td>$(tail -n $PAGE_LOG_LENGTH /data/sd/log/sampler.log | sed $SED_HTML_FILTER)</td></tr>" >> $STATUS_PAGE
fi
if [ -f /data/sd/log/streamer.log ]; then
    echo "<tr><td>Persistent streamer log</td><td>$(tail -n $PAGE_LOG_LENGTH /data/sd/log/streamer.log | sed $SED_HTML_FILTER)</td></tr>" >> $STATUS_PAGE
fi
if [ -f /data/sd/log/messages ]; then
    echo "<tr><td>Persistent monitor log</td><td>$(grep curb_hmon /data/sd/log/messages | tail -n $PAGE_LOG_LENGTH | sed $SED_HTML_FILTER)</td></tr>" >> $STATUS_PAGE
    echo "<tr><td>Persistent update log</td><td>$(grep curb_update /data/sd/log/messages | tail -n $PAGE_LOG_LENGTH | sed $SED_HTML_FILTER)</td></tr>" >> $STATUS_PAGE
fi
echo "</table>" >> $STATUS_PAGE
echo "</body>" >> $STATUS_PAGE
echo "</html>" >> $STATUS_PAGE

# Copy energy monitor web interface (deployet via install.sh)
[ -f /data/sd/www/energy.html ]      && cp /data/sd/www/energy.html      "$BASE_DIR/energy.html"      && chmod 644 "$BASE_DIR/energy.html"
[ -f /data/sd/www/settings.html ]    && cp /data/sd/www/settings.html    "$BASE_DIR/settings.html"    && chmod 644 "$BASE_DIR/settings.html"
[ -f /data/sd/www/calibration.html ] && cp /data/sd/www/calibration.html "$BASE_DIR/calibration.html" && chmod 644 "$BASE_DIR/calibration.html"
[ -f /data/sd/www/sysinfo.html ]    && cp /data/sd/www/sysinfo.html    "$BASE_DIR/sysinfo.html"    && chmod 644 "$BASE_DIR/sysinfo.html"

printf '{"date":"%s","serialNumber":"%s","hardwareVersion":"%s","modelNumber:":"%s","osVersion":"%s","softwareVersion":"%s","osRollbackRunning":"%s","uptime":"%s","free":"%s","ps":"%s", "eth0":"%s","eth1":"%s","wlan0":"%s","plc":"%s","plcstats":"%s","serverconn":"%s","storage":"%s","samplerLog":"%s","streamerLog":"%s","monitorLog":"%s","updateLog":"%s","persistentSamplerLog":"%s","persistentStreamerLog":"%s","persistentMonitorLog":"%s","persistentUpdateLog":"%s"}\n'\
 "$date" "$serialNumber" "$hardwareVersion" "$modelNumber" "$osVersion" "$softwareVersion" "$osRollbackRunning" "$uptime" "$free" "$ps" "$eth0" "$eth1" "$wlan0" "$plc" "$plcstats" " $pingstats" "$storage" "$samplerLog" "$streamerLog" "$monitorLog" "$updateLog" "$persistentSamplerLog" "$persistentStreamerLog" "$persistentMonitorLog" "$persistentUpdateLog"> $STATUS_JSON
