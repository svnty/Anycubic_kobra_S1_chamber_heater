#!/usr/bin/env python3
import socket
import struct
import time
import logging

MDNS_ADDR = "224.0.0.251"
MDNS_PORT = 5353
CACHE_FILE = "/tmp/chamber_heater_ip"
PERSISTENT_CACHE = "/userdata/chamber_heater_ip"
TARGET = "chamber-heater.local"
REFRESH_INTERVAL = 60
QUERY_TIMEOUT = 5.0

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("mdns_resolve")

def encode_dns_name(name):
    parts = name.encode("ascii").split(b".")
    result = b""
    for part in parts:
        result += struct.pack("B", len(part)) + part
    result += b"\x00"
    return result

def parse_dns_name(data, offset):
    labels = []
    original_offset = None
    while offset < len(data):
        length = data[offset]
        if length == 0:
            offset += 1
            break
        if (length & 0xC0) == 0xC0:
            if original_offset is None:
                original_offset = offset + 2
            pointer = struct.unpack("!H", data[offset:offset+2])[0] & 0x3FFF
            offset = pointer
            continue
        offset += 1
        labels.append(data[offset:offset+length].decode("ascii", errors="replace"))
        offset += length
    return ".".join(labels), (original_offset if original_offset is not None else offset)

def build_query(name):
    header = struct.pack("!HHHHHH", 0, 0, 1, 0, 0, 0)
    encoded = encode_dns_name(name)
    question = encoded + struct.pack("!HH", 1, 0x8001)
    return header + question

def parse_response(data, target):
    if len(data) < 12:
        return None
    flags = struct.unpack("!H", data[2:4])[0]
    if not (flags & 0x8000):
        return None
    ancount = struct.unpack("!H", data[6:8])[0]
    if ancount == 0:
        return None
    offset = 12
    qdcount = struct.unpack("!H", data[4:6])[0]
    for _ in range(qdcount):
        if offset >= len(data):
            return None
        _, offset = parse_dns_name(data, offset)
        offset += 4
    for _ in range(ancount):
        if offset >= len(data):
            return None
        name, offset = parse_dns_name(data, offset)
        if offset + 10 > len(data):
            return None
        rtype, rclass, ttl, rdlen = struct.unpack("!HHIH", data[offset:offset+10])
        offset += 10
        if (name.lower() == target.lower() and rtype == 1 and (rclass & 0x7FFF) == 1 and rdlen == 4):
            return socket.inet_ntoa(data[offset:offset+4])
        offset += rdlen
    return None

def resolve_once(target):
    query = build_query(target)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)
    sock.settimeout(QUERY_TIMEOUT)
    try:
        sock.sendto(query, (MDNS_ADDR, MDNS_PORT))
        deadline = time.monotonic() + QUERY_TIMEOUT
        while time.monotonic() < deadline:
            try:
                data, _ = sock.recvfrom(1500)
                ip = parse_response(data, target)
                if ip:
                    return ip
            except socket.timeout:
                break
    finally:
        sock.close()
    return None

def write_cache(ip):
    for path in [CACHE_FILE, PERSISTENT_CACHE]:
        try:
            with open(path, "w") as f:
                f.write(ip)
        except Exception as e:
            log.warning("Could not write cache %s: %s", path, e)
    log.info("Resolved %s -> %s", TARGET, ip)

def read_cache():
    for path in [CACHE_FILE, PERSISTENT_CACHE]:
        try:
            with open(path) as f:
                ip = f.read().strip()
                if ip:
                    return ip
        except Exception:
            continue
    return None

def main():
    log.info("Starting mDNS resolver for %s", TARGET)
    last_success = None
    while True:
        ip = resolve_once(TARGET)
        if ip:
            if ip != last_success:
                write_cache(ip)
                last_success = ip
        else:
            if last_success is None and read_cache() is None:
                log.warning("No cached IP available for %s", TARGET)
        time.sleep(REFRESH_INTERVAL)

if __name__ == "__main__":
    main()
