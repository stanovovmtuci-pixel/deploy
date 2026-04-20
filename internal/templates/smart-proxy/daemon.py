#!/usr/bin/env python3
import asyncio
import json
import logging
import os
import socket
import struct
import sys
import time
import threading
import urllib.request

sys.path.insert(0, '/usr/local/bin/smart-proxy')
import db
import tester

LOG_FILE = '/var/log/smart-proxy.log'
CONFIG_FILE = '/etc/smart-proxy/config.json'
DB_PATH = '/var/lib/smart-proxy/cache.db'

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(sys.stdout)
    ]
)
log = logging.getLogger("smart-proxy")

CONFIG = {}
TUNNEL_DOMAINS = []
DIRECT_TLDS = set()
DIRECT_DOMAINS = []
SPECIAL_DOMAINS = []
CACHE = {}
CACHE_LOCK = threading.Lock()


def load_config():
    global CONFIG
    with open(CONFIG_FILE) as f:
        CONFIG = json.load(f)
    tester.TEST_TIMEOUT = CONFIG.get("test_timeout", 3.0)
    tester.TLS_TIMEOUT = CONFIG.get("test_timeout", 3.0)
    tester.SLOW_THRESHOLD = CONFIG.get("test_slow_threshold", 1.5)
    log.info("Config loaded")


def build_lists():
    global TUNNEL_DOMAINS, DIRECT_TLDS, DIRECT_DOMAINS
    TUNNEL_DOMAINS = [d.lower() for d in CONFIG.get("tunnel_always", [])]
    direct_all = [d.lower() for d in CONFIG.get("direct_always", [])]
    DIRECT_TLDS = set()
    DIRECT_DOMAINS = []
    for d in direct_all:
        if "." not in d:
            DIRECT_TLDS.add(d)
        else:
            DIRECT_DOMAINS.append(d)
    log.info("Lists built: tunnel=" + str(len(TUNNEL_DOMAINS)) +
             " direct_tlds=" + str(len(DIRECT_TLDS)) +
             " direct_domains=" + str(len(DIRECT_DOMAINS)))


def load_special_category():
    global SPECIAL_DOMAINS
    url = CONFIG.get("special_category_url", "")
    if not url:
        return
    domains = []
    try:
        req = urllib.request.urlopen(url, timeout=15)
        for line in req.read().decode().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("full:"):
                domains.append(line[5:])
            elif line.startswith("domain:"):
                domains.append(line[7:])
            elif line.startswith("regexp:") or line.startswith("keyword:"):
                continue
            else:
                domains.append(line)
        SPECIAL_DOMAINS = domains
        log.info("Special category loaded: " + str(len(SPECIAL_DOMAINS)) + " domains")
    except Exception as e:
        log.error("Failed to load special category: " + str(e))


def load_cache():
    global CACHE
    all_entries = db.load_all()
    with CACHE_LOCK:
        CACHE = {d: e["decision"] for d, e in all_entries.items()}
    log.info("Cache loaded: " + str(len(CACHE)) + " entries")


def get_decision(domain):
    domain = domain.lower().rstrip(".")
    parts = domain.split(".")

    # 1. Ручные переопределения — наивысший приоритет
    manual = db.get_manual(domain)
    if manual:
        return manual["decision"]

    # Проверяем суффиксы для manual
    for i in range(len(parts)):
        suffix = ".".join(parts[i:])
        manual = db.get_manual(suffix)
        if manual:
            return manual["decision"]

    # 2. TLD зона (.ru, .рф и т.д.)
    tld = parts[-1] if parts else ""
    if tld in DIRECT_TLDS:
        return "direct"

    # 3. direct_always (полные домены и суффиксы)
    for d in DIRECT_DOMAINS:
        if domain == d or domain.endswith("." + d):
            return "direct"

    # 4. tunnel_always
    for d in TUNNEL_DOMAINS:
        if domain == d or domain.endswith("." + d):
            return "tunnel"

    # 5. special category
    for d in SPECIAL_DOMAINS:
        if domain == d or domain.endswith("." + d):
            return "tunnel"

    # 6. Кэш
    with CACHE_LOCK:
        if domain in CACHE:
            return CACHE[domain]

    # 7. Новый домен — тестируем в фоне, пока возвращаем direct
    threading.Thread(target=test_and_cache, args=(domain,), daemon=True).start()
    return "direct"


def test_and_cache(domain):
    with CACHE_LOCK:
        if domain in CACHE:
            return
        CACHE[domain] = "testing"

    log.info("Testing new domain: " + domain)
    try:
        result = tester.test_domain(domain)
        db.save(
            domain, result.decision, "auto-test",
            block_type=result.block_type,
            tcp_time=result.tcp_time,
            tls_time=result.tls_time,
            http_status=result.http_status,
            redirect_url=result.redirect_url,
            notes=result.notes
        )
        with CACHE_LOCK:
            CACHE[domain] = result.decision
        log.info("Cached: " + domain + " -> " + result.decision)
    except Exception as e:
        log.error("Test failed for " + domain + ": " + str(e))
        with CACHE_LOCK:
            CACHE.pop(domain, None)


def startup_test():
    log.info("Starting startup tests...")
    tested = 0
    for domain in list(TUNNEL_DOMAINS):
        if "/" in domain or ":" in domain or not "." in domain:
            continue
        with CACHE_LOCK:
            if domain in CACHE:
                continue
        try:
            result = tester.test_domain(domain)
            db.save(
                domain, result.decision, "startup-test",
                block_type=result.block_type,
                tcp_time=result.tcp_time,
                tls_time=result.tls_time,
                http_status=result.http_status,
                redirect_url=result.redirect_url,
                notes=result.notes
            )
            with CACHE_LOCK:
                CACHE[domain] = result.decision
            tested += 1
        except Exception as e:
            log.error("Startup test failed for " + domain + ": " + str(e))
    log.info("Startup tests done: " + str(tested) + " domains tested")


async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except Exception:
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def forward_direct(reader, writer, host, port):
    try:
        r, w = await asyncio.wait_for(
            asyncio.open_connection(host, port), timeout=10
        )
        writer.write(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
        await writer.drain()
        await asyncio.gather(pipe(reader, w), pipe(r, writer))
    except Exception as e:
        log.debug("Direct error " + host + ": " + str(e))
        try:
            writer.write(b"\x05\x05\x00\x01\x00\x00\x00\x00\x00\x00")
            writer.close()
        except Exception:
            pass


async def forward_tunnel(reader, writer, host, port):
    tunnel_host = CONFIG.get("tunnel_socks5_host", "127.0.0.1")
    tunnel_port = CONFIG.get("tunnel_socks5_port", 40001)
    try:
        r, w = await asyncio.wait_for(
            asyncio.open_connection(tunnel_host, tunnel_port), timeout=10
        )
        w.write(b"\x05\x01\x00")
        await w.drain()
        await r.read(2)

        host_b = host.encode()
        w.write(
            b"\x05\x01\x00\x03" +
            bytes([len(host_b)]) +
            host_b +
            struct.pack("!H", port)
        )
        await w.drain()
        await r.read(10)

        writer.write(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
        await writer.drain()
        await asyncio.gather(pipe(reader, w), pipe(r, writer))
    except Exception as e:
        log.debug("Tunnel error " + host + ": " + str(e))
        try:
            writer.write(b"\x05\x05\x00\x01\x00\x00\x00\x00\x00\x00")
            writer.close()
        except Exception:
            pass


async def handle_client(reader, writer):
    try:
        data = await asyncio.wait_for(reader.read(2), timeout=10)
        if len(data) < 2 or data[0] != 0x05:
            writer.close()
            return

        nmethods = data[1]
        await reader.read(nmethods)
        writer.write(b"\x05\x00")
        await writer.drain()

        data = await asyncio.wait_for(reader.read(4), timeout=10)
        if len(data) < 4 or data[0] != 0x05 or data[1] != 0x01:
            writer.close()
            return

        atyp = data[3]
        if atyp == 0x01:
            addr_b = await reader.read(4)
            host = socket.inet_ntoa(addr_b)
        elif atyp == 0x03:
            length = (await reader.read(1))[0]
            host = (await reader.read(length)).decode(errors="ignore")
        elif atyp == 0x04:
            addr_b = await reader.read(16)
            host = socket.inet_ntop(socket.AF_INET6, addr_b)
        else:
            writer.close()
            return

        port_b = await reader.read(2)
        port = struct.unpack("!H", port_b)[0]

        decision = get_decision(host)
        log.debug(host + ":" + str(port) + " -> " + decision)
        try:
            import datetime
            ts = datetime.datetime.now().strftime("%H:%M:%S")
            with open("/var/log/smart-proxy-access.log", "a") as af:
                af.write(ts + " " + decision.upper() + " " + host + "\n")
        except Exception:
            pass

        if decision == "tunnel":
            await forward_tunnel(reader, writer, host, port)
        else:
            await forward_direct(reader, writer, host, port)

    except Exception as e:
        log.debug("Client error: " + str(e))
        try:
            writer.close()
        except Exception:
            pass


async def main():
    load_config()
    build_lists()
    db.init(DB_PATH)
    load_cache()
    load_special_category()

    loop = asyncio.get_event_loop()
    loop.run_in_executor(None, startup_test)

    host = CONFIG.get("listen_host", "127.0.0.1")
    port = CONFIG.get("listen_port", 7070)

    server = await asyncio.start_server(handle_client, host, port)
    log.info("Smart proxy listening on " + host + ":" + str(port))

    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
