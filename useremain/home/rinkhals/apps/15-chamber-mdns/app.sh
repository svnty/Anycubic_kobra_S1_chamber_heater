#!/bin/sh
PIDFILE=/tmp/chamber_mdns.pid
SCRIPT=/useremain/home/rinkhals/apps/15-chamber-mdns/mdns_resolve.py
PERSISTENT_CACHE=/userdata/chamber_heater_ip
RUNTIME_CACHE=/tmp/chamber_heater_ip

case "$1" in
    start)
        if [ -f $PERSISTENT_CACHE ] && [ ! -f $RUNTIME_CACHE ]; then
            cp $PERSISTENT_CACHE $RUNTIME_CACHE
        fi
        python3 $SCRIPT > /dev/null 2>&1 &
        echo $! > $PIDFILE
        ;;
    stop)
        if [ -f $PIDFILE ]; then
            kill $(cat $PIDFILE) 2>/dev/null
            rm -f $PIDFILE
        fi
        if [ -f $RUNTIME_CACHE ]; then
            cp $RUNTIME_CACHE $PERSISTENT_CACHE
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
        echo "Usage: $0 {start|stop|restart|status}"; exit 1
        ;;
esac
