#!/bin/sh
PIDFILE=/tmp/chamber_spy.pid
LOG_FILE="/tmp/gklib.log"
RUNTIME_CACHE="/tmp/chamber_heater_ip"

run_spy_loop() {
    while [ ! -f "$LOG_FILE" ]; do sleep 1; done
    
    tail -n 0 -F "$LOG_FILE" | while read -r line; do
        case "$line" in
            *"web hook do script: M141 S"*)
                # Extract the digits that immediately follow 'M141 S'
                RAW_TARGET=$(echo "$line" | sed -n 's/.*M141 S\([0-9]*\).*/\1/p' | tr -d '\r\n ')
                
                if [ -n "$RAW_TARGET" ]; then
                    if [ -f "$RUNTIME_CACHE" ]; then
                        ESP32_IP=$(cat "$RUNTIME_CACHE" | tr -d '\r\n ')
                    else
                        ESP32_IP=""
                    fi

                    if [ -n "$ESP32_IP" ]; then
                        if [ "$RAW_TARGET" -lt 40 ]; then
                            curl -s --max-time 3 "http://$ESP32_IP/?target=0" > /dev/null &
                        else
                            curl -s --max-time 3 "http://$ESP32_IP/?target=$RAW_TARGET" > /dev/null &
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
root@kobra-ks1-ea93:/root# 