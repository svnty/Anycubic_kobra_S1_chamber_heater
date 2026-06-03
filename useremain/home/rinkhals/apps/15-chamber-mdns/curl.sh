#!/bin/sh
IP=$(cat /tmp/chamber_heater_ip 2>/dev/null || cat /userdata/chamber_heater_ip 2>/dev/null)
if [ -z "$IP" ]; then
    echo "No ESP32 IP cached" >&2
    exit 1
fi
curl -s -X POST "http://$IP/?target=$1"