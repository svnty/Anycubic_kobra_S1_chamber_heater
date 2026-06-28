#!/bin/sh
PIDFILE="/tmp/chamber_spy.pid"
SCRIPT="/useremain/home/rinkhals/apps/99-chamber-controller/chamber_controller.py"

case "$1" in
    start)
        if [ -f $PIDFILE ] && kill -0 $(cat $PIDFILE) 2>/dev/null; then
            echo "Already running"
        else
            python3 $SCRIPT > /dev/null 2>&1 &
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