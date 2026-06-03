#!/bin/sh
PIDFILE="/tmp/chamber_spy.pid"
RUNTIME_CACHE="/tmp/chamber_heater_ip"
MDNS_SCRIPT="/userdata/chamber/mdns_resolve.py"
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
    LAST_TARGET_SENT="-1"
    echo "[DEBUG_MAIN] Loop engine started. Polling interval: 5s" >> "$DEBUG_LOG"
    
    while true; do
        STATS_BLOB=$(curl -s "http://localhost:7125/printer/objects/query?print_stats")
        
        STATE=$(echo "$STATS_BLOB" | grep -o '"state": "[^"]*"' | head -n 1 | sed 's/.*"state": "\([^"]*\)".*/\1/')
        CURRENT_FILE=$(echo "$STATS_BLOB" | grep -o '"filename": "[^"]*"' | head -n 1 | sed 's/.*"filename": "\([^"]*\)".*/\1/')

        case "$RAW_STATE" in
            *)
                # Recalculate variables safely without matching blocks breaking
                STATE_CLEAN=$(echo "$STATE" | tr -d '\r\n ')
                ;;
        esac

        case "$STATE" in
            *"printing"*)
                if [ -n "$CURRENT_FILE" ]; then
                    FULL_PATH="$GCODES_BASE/$CURRENT_FILE"

                    if [ -f "$FULL_PATH" ]; then
                        RAW_TARGET=$(grep "M141" "$FULL_PATH" | sed -n 's/.*M141.*S\([0-9]*\).*/\1/p' | head -n 1 | tr -d '\r\n ')
                        [ -z "$RAW_TARGET" ] && RAW_TARGET="0"

                        # FIX: Fire if it's a brand new file OR if the target state has drifted
                        if [ "$CURRENT_FILE" != "$LAST_FILE" ] || [ "$RAW_TARGET" != "$LAST_TARGET_SENT" ]; then
                            LAST_FILE="$CURRENT_FILE"
                            echo "[DEBUG_PATH] Match found. Target file: [$FULL_PATH]" >> "$DEBUG_LOG"
                            echo "[DEBUG_GREP] Parsed target: [$RAW_TARGET]" >> "$DEBUG_LOG"

                            if [ -n "$RAW_TARGET" ]; then
                                ACTIVE_IP=$(get_valid_ip)
                                
                                if [ -n "$ACTIVE_IP" ] && [ "$ACTIVE_IP" != "0.0.0.0" ]; then
                                    if [ "$RAW_TARGET" -lt 40 ]; then
                                        echo "[DEBUG_CURL] Sending 0C safety shutdown target..." >> "$DEBUG_LOG"
                                        curl -s --connect-timeout 2 --max-time 4 "http://$ACTIVE_IP/?target=0" > /dev/null 2>&1
                                        echo "[DEBUG_CURL_RESULT] Exit status: [$?]" >> "$DEBUG_LOG"
                                        LAST_TARGET_SENT="$RAW_TARGET"
                                    else
                                        echo "[DEBUG_CURL] Synchronously firing target payload to http://$ACTIVE_IP" >> "$DEBUG_LOG"
                                        curl -s --connect-timeout 2 --max-time 4 "http://$ACTIVE_IP/?target=$RAW_TARGET" > /dev/null 2>&1
                                        echo "[DEBUG_CURL_RESULT] Exit status: [$?]" >> "$DEBUG_LOG"
                                        LAST_TARGET_SENT="$RAW_TARGET"
                                    fi
                                else
                                    echo "[DEBUG_ERR] Dynamic IP lookup returned empty." >> "$DEBUG_LOG"
                               fi
                            fi
                        fi
                    fi
                fi
                ;;
            *"standby"*|*"cancelled"*|*"complete"*)
                if [ -n "$LAST_FILE" ]; then
                    echo "[DEBUG_SHUTDOWN] Print ended. Disabling heater relays." >> "$DEBUG_LOG"
                    LAST_FILE=""  
                    LAST_TARGET_SENT="-1"
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
