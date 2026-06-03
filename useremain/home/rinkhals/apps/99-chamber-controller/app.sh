#!/bin/sh
PIDFILE=/tmp/chamber_spy.pid
LOG_FILE="/tmp/gklib.log"
RUNTIME_CACHE="/tmp/chamber_heater_ip"
MDNS_SCRIPT="/userdata/chamber/mdns_resolve.py"

get_valid_ip() {
    # 1. Try reading the current mDNS runtime cache file
    if [ -f "$RUNTIME_CACHE" ]; then
        CURRENT_IP=$(cat "$RUNTIME_CACHE" | tr -d '\r\n ')
        # Verify if this IP is actually alive on the network right now
        if [ -n "$CURRENT_IP" ] && ping -c 1 -W 1 "$CURRENT_IP" >/dev/null 2>&1; then
            echo "$CURRENT_IP"
            return 0
        fi
    fi

    # 2. Cache is stale or missing! Force an emergency background re-resolve 
    # to wake up the 15-chamber-mdns layer if python3 is available
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

run_spy_loop() {
    while [ ! -f "$LOG_FILE" ]; do sleep 2; done

    tail -n 0 -F "$LOG_FILE" | while read -r line; do
        case "$line" in
            *"web hook do script: M141 S"*)
                RAW_TARGET=$(echo "$line" | sed -n 's/.*M141 S\([0-9]*\).*/\1/p' | tr -d '\r\n ')
                
                if [ -n "$RAW_TARGET" ]; then
                    # Dynamically fetch an IP that passes validation
                    ACTIVE_IP=$(get_valid_ip)

                    if [ -n "$ACTIVE_IP" ] && [ "$ACTIVE_IP" != "0.0.0.0" ]; then
                        if [ "$RAW_TARGET" -lt 40 ]; then
                            (curl -s --connect-timeout 2 --max-time 4 "http://$ACTIVE_IP/?target=0" > /dev/null 2>&1) &
                        else
                            (curl -s --connect-timeout 2 --max-time 4 "http://$ACTIVE_IP/?target=$RAW_TARGET" > /dev/null 2>&1) &
                        fi
                    fi
                fi
                ;;
        esac
    done
}

case "$1" in
    start)
        if [ -f $PIDFILE ] && kill -0 $(cat $PIDFILE) 2>/dev/null; then
            echo "Already running"
        else
            run_spy_loop > /dev/null 2>&1 &
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