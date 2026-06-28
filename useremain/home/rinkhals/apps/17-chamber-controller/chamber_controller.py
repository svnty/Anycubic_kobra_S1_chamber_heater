#!/usr/bin/env python3
import os
import re
import sys
import time
import json
import urllib.request
import urllib.error
from datetime import datetime

PIDFILE = "/tmp/chamber_spy.pid"
RUNTIME_CACHE = "/tmp/chamber_heater_ip"
PERSISTENT_CACHE = "/userdata/chamber_heater_ip"
GCODES_BASE = "/userdata/app/gk/printer_data/gcodes"
DEBUG_LOG = "/tmp/chamber_debug.log"

def log_debug(message):
    try:
        timestamp = datetime.now().strftime('[%Y-%m-%d %H:%M:%S]')
        with open(DEBUG_LOG, "a") as f:
            f.write(f"{timestamp} {message}\n")
    except Exception as e:
        print(f"Error writing to log: {e}", file=sys.stderr)

def get_valid_ip():
    for cache_path in [RUNTIME_CACHE, PERSISTENT_CACHE]:
        if os.path.exists(cache_path):
            try:
                with open(cache_path, "r") as f:
                    ip = f.read().strip()
                if ip and ip != "0.0.0.0":
                    return ip
            except Exception:
                pass
    return None

def parse_gcode_file(filename):
    full_path = os.path.join(GCODES_BASE, filename)
    if not os.path.isfile(full_path):
        log_debug(f"[DEBUG_ERR] File not found on disk: [{full_path}]")
        return None, None

    raw_target = 0
    total_estimate = 1800

    try:
        # Read first 500 lines for M141
        with open(full_path, "r", encoding="utf-8", errors="ignore") as f:
            for i, line in enumerate(f):
                if i >= 500:
                    break
                if "M141" in line:
                    match = re.search(r'M141.*?S(\d+)', line)
                    if match:
                        raw_target = int(match.group(1))
                        break

        # Read last 128KB of the file for the print time estimate
        try:
            with open(full_path, "rb") as f:
                f.seek(0, os.SEEK_END)
                size = f.tell()
                read_size = min(size, 131072)
                f.seek(-read_size, os.SEEK_END)
                last_chunk = f.read(read_size).decode("utf-8", errors="ignore")
                
                time_match = re.search(r'estimated printing time \(normal mode\)\s*=\s*(.*)', last_chunk, re.IGNORECASE)
                if time_match:
                    time_str = time_match.group(1).strip()
                    h = re.search(r'(\d+)h', time_str)
                    m = re.search(r'(\d+)m', time_str)
                    s_match = re.search(r'(\d+)s', time_str)
                    total_estimate = (int(h.group(1)) * 3600 if h else 0) + \
                                     (int(m.group(1)) * 60 if m else 0) + \
                                     (int(s_match.group(1)) if s_match else 0)
        except Exception as e:
            log_debug(f"[DEBUG_ERR] Error parsing end of gcode file: {e}")

    except Exception as e:
        log_debug(f"[DEBUG_ERR] Error reading gcode file: {e}")

    return raw_target, total_estimate

def run_monitor_loop():
    log_debug("[DEBUG_MAIN] Loop engine started. Polling interval: 5s")
    last_file = ""

    while True:
        try:
            req = urllib.request.Request("http://localhost:7125/printer/objects/query?print_stats")
            with urllib.request.urlopen(req, timeout=3) as response:
                stats_blob = json.loads(response.read().decode("utf-8"))
            
            print_stats = stats_blob.get('result', {}).get('status', {}).get('print_stats', {})
            state = print_stats.get('state', '')
            current_file = print_stats.get('filename', '')
            duration = int(float(print_stats.get('print_duration', 0.0)))
        except Exception as e:
            time.sleep(5)
            continue

        if "printing" in state:
            if current_file:
                raw_target, total_estimate = parse_gcode_file(current_file)
                if raw_target is not None:
                    active_ip = get_valid_ip()
                    if active_ip:
                        try:
                            esp_url = f"http://{active_ip}/"
                            esp_req = urllib.request.Request(esp_url)
                            with urllib.request.urlopen(esp_req, timeout=3) as resp:
                                esp32_status = resp.read().decode("utf-8", errors="ignore")
                            
                            match = re.search(r'Target Temp:\s*([\d.]+)', esp32_status)
                            if match:
                                live_hardware_target = int(float(match.group(1)))
                            else:
                                live_hardware_target = -1
                                log_debug(f"[DEBUG_WARN] Could not parse Target Temp from ESP32 response")

                            time_remaining = total_estimate - duration
                            log_debug(f"[DEBUG_LOOP] Polled State: [{state}] | Required: [{raw_target}] | ESP32 Target: [{live_hardware_target}] | GCode Estimate: [{total_estimate}] | Remaining: [{time_remaining}] | Elapsed: [{duration}]")

                            if time_remaining < 500:
                                raw_target = 0

                            if raw_target != live_hardware_target:
                                last_file = current_file
                                log_debug(f"[DEBUG_PATH] Mismatch detected! Correcting hardware target to [{raw_target}]")
                                
                                if raw_target < 40:
                                    target_url = f"http://{active_ip}/?target=0&timer=0"
                                else:
                                    target_url = f"http://{active_ip}/?target={raw_target}&timer={time_remaining}"
                                
                                try:
                                    with urllib.request.urlopen(target_url, timeout=4) as _:
                                        pass
                                    log_debug("[DEBUG_CURL_RESULT] Correction status: [0]")
                                except Exception as curl_err:
                                    log_debug(f"[DEBUG_CURL_RESULT] Correction failed: {curl_err}")
                        except Exception as esp_err:
                            log_debug(f"[DEBUG_ERR] Failed to communicate with ESP32 at {active_ip}: {esp_err}")
                    else:
                        log_debug("[DEBUG_ERR] Dynamic IP lookup returned empty.")
        elif state in ["standby", "cancelled", "complete"]:
            if last_file:
                log_debug("[DEBUG_SHUTDOWN] Print ended. Disabling heater relays.")
                last_file = ""
                active_ip = get_valid_ip()
                if active_ip:
                    try:
                        shutdown_url = f"http://{active_ip}/?target=0"
                        with urllib.request.urlopen(shutdown_url, timeout=4) as _:
                            pass
                    except Exception as shutdown_err:
                        log_debug(f"[DEBUG_ERR] Failed to send shutdown command to ESP32: {shutdown_err}")

        time.sleep(5)

if __name__ == "__main__":
    run_monitor_loop()
