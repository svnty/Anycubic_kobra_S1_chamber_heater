#!/bin/sh
PIDFILE="/tmp/chamber_spy.pid"
RUNTIME_CACHE="/tmp/chamber_heater_ip"
MDNS_SCRIPT="/useremain/home/rinkhals/apps/15-chamber-mdns/mdns_resolve.py"
GCODES_BASE="/userdata/app/gk/printer_data/gcodes"
DEBUG_LOG="/tmp/chamber_debug.log"

echo "=== CHAMBER CONTROLLER DAEMON LOG INITIALIZED ===" > "$DEBUG_LOG"

get_valid_ip() {
    if [ -f "$RUNTIME_CACHE" ]; then
        CURRENT_IP=$(cat "$RUNTIME_CACHE" | tr -d '\r\n ')
        if [ -n "$CURRENT_IP" ] && ping -c 1 -W 1 "$CURRENT_IP" >/dev/null 2>&1; then
            echo "$CURRENT_IP"
            return 0
        fi
    fi

    if [ -f "$MDNS_SCRIPT" ]; then
        python3 "$MDNS_SCRIPT" >/dev/null 2>&1
        if [ -f "$RUNTIME_CACHE" ]; then
            NEW_IP=$(cat "$RUNTIME_CACHE" | tr -d '\r\n ')
            echo "$NEW_IP"
            return 0
        fi
    fi
    echo ""
}

run_monitor_loop() {
    LAST_FILE=""
    echo "[DEBUG_MAIN] Loop engine started. Polling interval: 5s" >> "$DEBUG_LOG"
    
    while true; do
        STATS_BLOB=$(curl -s "http://localhost:7125/printer/objects/query?print_stats")
        
        STATE=$(echo "$STATS_BLOB" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d['result']['status']['print_stats']['state'])" 2>/dev/null)
        CURRENT_FILE=$(echo "$STATS_BLOB" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d['result']['status']['print_stats']['filename'])" 2>/dev/null)

        case "$STATE" in
            *"printing"*)
                if [ -n "$CURRENT_FILE" ]; then
                    FULL_PATH="$GCODES_BASE/$CURRENT_FILE"

                    if [ -f "$FULL_PATH" ]; then
                        RAW_TARGET=$(head -n 500 "$FULL_PATH" | grep "M141" | sed -n 's/.*M141.*S\([0-9]*\).*/\1/p' | head -n 1 | tr -d '\r\n ')
                        [ -z "$RAW_TARGET" ] && RAW_TARGET="0"

                        ACTIVE_IP=$(get_valid_ip)
                        
                        if [ -n "$ACTIVE_IP" ] && [ "$ACTIVE_IP" != "0.0.0.0" ]; then
                            # Query the ESP32 directly to see what its current hardware target is set to
                            ESP32_STATUS=$(curl -s --connect-timeout 2 --max-time 3 "http://$ACTIVE_IP/")
                            LIVE_HARDWARE_TARGET=$(echo "$ESP32_STATUS" | grep "Target Temp:" | awk '{print $3}' | cut -d'.' -f1 | tr -d '\r\n ')

                            echo "[DEBUG_LOOP] Polled State: [$STATE] | Required: [$RAW_TARGET] | ESP32 Target: [$LIVE_HARDWARE_TARGET]" >> "$DEBUG_LOG"

                            # If the ESP32 reset to 0, or doesn't match the G-code requirement, fire the payload
                            if [ "$RAW_TARGET" != "$LIVE_HARDWARE_TARGET" ]; then
                                LAST_FILE="$CURRENT_FILE"
                                echo "[DEBUG_PATH] Mismatch detected! Correcting hardware target to [$RAW_TARGET]" >> "$DEBUG_LOG"

                                if [ "$RAW_TARGET" -lt 40 ]; then
                                    curl -s --connect-timeout 2 --max-time 4 "http://$ACTIVE_IP/?target=0" > /dev/null 2>&1
                                else
                                    curl -s --connect-timeout 2 --max-time 4 "http://$ACTIVE_IP/?target=$RAW_TARGET" > /dev/null 2>&1
                                    echo "[DEBUG_CURL_RESULT] Correction status: [$?]" >> "$DEBUG_LOG"
                                fi
                            fi
                        else
                            echo "[DEBUG_ERR] Dynamic IP lookup returned empty." >> "$DEBUG_LOG"
                        fi
                    else
                        echo "[DEBUG_ERR] File not found on disk: [$FULL_PATH]" >> "$DEBUG_LOG"
                    fi
                fi
                ;;
            *"standby"*|*"cancelled"*|*"complete"*)
                if [ -n "$LAST_FILE" ]; then
                    echo "[DEBUG_SHUTDOWN] Print ended. Disabling heater relays." >> "$DEBUG_LOG"
                    LAST_FILE=""  
                    ACTIVE_IP=$(get_valid_ip)
                    if [ -n "$ACTIVE_IP" ] && [ "$ACTIVE_IP" != "0.0.0.0" ]; then
                        curl -s --connect-timeout 2 --max-time 4 "http://$ACTIVE_IP/?target=0" > /dev/null 2>&1
                    fi
                fi
                ;;
        esac
        
        sleep 5
    done
}

case "$1" in
    start)
        if [ -f $PIDFILE ] && kill -0 $(cat $PIDFILE) 2>/dev/null; then
            echo "Already running"
        else
            run_monitor_loop > /dev/null 2>&1 &
            echo $! > $PIDFILE
            echo "Started"
        fi
        ;;
    stop)
        if [ -f $PIDFILE ]; then
            kill $(cat $PIDFILE) 2>/dev/null
            rm -f $PIDFILE
            echo "Stopped"
        else
            echo "Not running"
        fi
        ;;
    restart)
        $0 stop; sleep 1; $0 start
        ;;
    status)
        if [ -f $PIDFILE ] && kill -0 $(cat $PIDFILE) 2>/dev/null; then
            echo "running"
        else
            echo "stopped"
        fi
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac