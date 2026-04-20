import asyncio
import socket
import ssl
import time
import urllib.request
import urllib.error
import logging

log = logging.getLogger("smart-proxy.tester")

TEST_TIMEOUT = 3.0
TLS_TIMEOUT = 3.0
HTTP_TIMEOUT = 5.0
SLOW_THRESHOLD = 1.5
RETRY_DELAY = 1.0
MAX_RETRIES = 2
CONTENT_READ_BYTES = 4096

STRONG_KEYWORDS = [
    "block", "ban", "restrict", "unavailab",
    "forbid", "forbidden", "prohibit", "sanction", "denied",
]

CONTEXT_KEYWORDS = [
    "geo", "region", "country", "russia",
    "access", "limited", "not-support",
]

GEO_BLOCK_CONTENT_MARKERS = [
    "not available in your country",
    "not available in your region",
    "not available in russia",
    "geo-blocked", "geo_blocked",
    "country_blocked", "region_blocked",
    "country not supported",
    "service is not available in",
    "restricted in your",
    "unavailable in your",
    "not available for your region",
    "geo_restriction", "geo-restriction",
    "not_available_region",
    "country-block", "region-block",
    "access is restricted",
    "this content is not available",
    "not accessible in your country",
    "blocked in your region",
    "unavailable in russia",
    "недоступно в вашем регионе",
    "недоступно в вашей стране",
    "заблокировано в вашем регионе",
    "ограничено в вашем регионе",
    "недоступен в России",
    "сервис недоступен в вашем регионе",
    "контент недоступен",
]


def is_blocked_redirect(location_url):
    if not location_url:
        return False
    url_lower = location_url.lower()
    strong_hits = [k for k in STRONG_KEYWORDS if k in url_lower]
    context_hits = [k for k in CONTEXT_KEYWORDS if k in url_lower]
    return (
        len(strong_hits) >= 1 or
        len(context_hits) >= 2 or
        (len(strong_hits) >= 1 and len(context_hits) >= 1)
    )


def is_blocked_content(content_text):
    if not content_text:
        return False
    text_lower = content_text.lower()
    for marker in GEO_BLOCK_CONTENT_MARKERS:
        if marker in text_lower:
            log.debug("Content marker found: " + marker)
            return True
    strong_hits = [k for k in STRONG_KEYWORDS if k in text_lower]
    context_hits = [k for k in CONTEXT_KEYWORDS if k in text_lower]
    if len(strong_hits) >= 1 and len(context_hits) >= 1:
        log.debug("Content keyword combo: strong=" + str(strong_hits) +
                  " context=" + str(context_hits))
        return True
    return False


def tcp_connect(host, port, timeout):
    start = time.time()
    try:
        sock = socket.create_connection((host, port), timeout=timeout)
        elapsed = time.time() - start
        sock.close()
        return True, elapsed
    except Exception as e:
        return False, None


def tls_handshake(host, port, timeout):
    start = time.time()
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        sock = socket.create_connection((host, port), timeout=timeout)
        tls_sock = ctx.wrap_socket(sock, server_hostname=host,
                                   do_handshake_on_connect=False)
        tls_sock.settimeout(timeout)
        tls_sock.do_handshake()
        elapsed = time.time() - start
        tls_sock.close()
        return True, elapsed
    except Exception as e:
        return False, None


def http_check(host, port, use_tls, timeout):
    scheme = "https" if use_tls else "http"
    url = scheme + "://" + host + "/"
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE

        req = urllib.request.Request(
            url,
            headers={"User-Agent": "Mozilla/5.0 (compatible; curl/7.88)"},
            method="GET"
        )
        handler = urllib.request.HTTPSHandler(context=ctx) if use_tls \
            else urllib.request.HTTPHandler()
        opener = urllib.request.build_opener(handler)
        opener.addheaders = []

        start = time.time()

        # Не следуем редиректам автоматически
        class NoRedirect(urllib.request.HTTPErrorProcessor):
            def http_response(self, request, response):
                return response
            https_response = http_response

        opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=ctx) if use_tls
            else urllib.request.HTTPHandler(),
            NoRedirect()
        )

        response = opener.open(req, timeout=timeout)
        elapsed = time.time() - start

        status = response.status
        location = response.headers.get("Location", "")
        content = response.read(CONTENT_READ_BYTES).decode("utf-8", errors="ignore")

        return {
            "ok": True,
            "status": status,
            "location": location,
            "content": content,
            "time": elapsed
        }

    except urllib.error.HTTPError as e:
        elapsed = time.time() - start if 'start' in dir() else None
        location = e.headers.get("Location", "") if e.headers else ""
        try:
            content = e.read(CONTENT_READ_BYTES).decode("utf-8", errors="ignore")
        except:
            content = ""
        return {
            "ok": True,
            "status": e.code,
            "location": location,
            "content": content,
            "time": elapsed
        }
    except Exception as e:
        return {"ok": False, "error": str(e), "time": None}


class TestResult:
    def __init__(self):
        self.decision = None
        self.block_type = None
        self.tcp_time = None
        self.tls_time = None
        self.http_status = None
        self.redirect_url = None
        self.notes = ""
        self.port_used = None

    def __repr__(self):
        return (
            "TestResult(decision=" + str(self.decision) +
            " block_type=" + str(self.block_type) +
            " port=" + str(self.port_used) +
            " tcp=" + str(round(self.tcp_time, 3) if self.tcp_time else None) +
            " tls=" + str(round(self.tls_time, 3) if self.tls_time else None) +
            " http=" + str(self.http_status) + ")"
        )


def test_domain(domain):
    result = TestResult()

    # Шаг 1: TCP на 443
    log.debug("TCP test :443 for " + domain)
    tcp_ok, tcp_time = tcp_connect(domain, 443, TEST_TIMEOUT)

    if not tcp_ok:
        log.debug("TCP :443 failed, retrying...")
        time.sleep(RETRY_DELAY)
        tcp_ok, tcp_time = tcp_connect(domain, 443, TEST_TIMEOUT)

    if not tcp_ok:
        # Пробуем 80
        log.debug("TCP :443 failed twice, trying :80")
        tcp_ok_80, tcp_time_80 = tcp_connect(domain, 80, TEST_TIMEOUT)
        if not tcp_ok_80:
            time.sleep(RETRY_DELAY)
            tcp_ok_80, tcp_time_80 = tcp_connect(domain, 80, TEST_TIMEOUT)

        if not tcp_ok_80:
            result.decision = "tunnel"
            result.block_type = "rkn"
            result.notes = "TCP failed on both 443 and 80"
            log.info(domain + " -> tunnel (TCP blocked both ports)")
            return result

        # 80 работает, проверяем HTTP
        result.tcp_time = tcp_time_80
        result.port_used = 80
        http = http_check(domain, 80, False, HTTP_TIMEOUT)

        if not http["ok"]:
            result.decision = "tunnel"
            result.block_type = "dpi"
            result.notes = "HTTP on :80 failed"
            return result

        result.http_status = http.get("status")
        location = http.get("location", "")
        content = http.get("content", "")

        if http.get("status") == 451:
            result.decision = "tunnel"
            result.block_type = "rkn"
            result.notes = "HTTP 451"
            return result

        if is_blocked_redirect(location):
            result.decision = "tunnel"
            result.block_type = "geo-service"
            result.redirect_url = location
            result.notes = "Blocked redirect on :80: " + location
            return result

        if is_blocked_content(content):
            result.decision = "tunnel"
            result.block_type = "geo-service"
            result.notes = "Blocked content marker on :80"
            return result

        result.decision = "direct"
        result.notes = "OK on :80"
        log.info(domain + " -> direct (HTTP :80 OK)")
        return result

    # TCP 443 прошёл
    result.tcp_time = tcp_time
    result.port_used = 443

    if tcp_time > SLOW_THRESHOLD:
        log.debug("TCP :443 slow (" + str(round(tcp_time, 3)) + "s), retrying")
        time.sleep(RETRY_DELAY)
        tcp_ok2, tcp_time2 = tcp_connect(domain, 443, TEST_TIMEOUT)
        if tcp_ok2:
            if tcp_time2 > SLOW_THRESHOLD:
                result.decision = "tunnel"
                result.block_type = "dpi"
                result.notes = "TCP slow on both attempts"
                log.info(domain + " -> tunnel (TCP slow x2)")
                return result
            result.tcp_time = tcp_time2

    # Шаг 2: TLS handshake
    log.debug("TLS test for " + domain)
    tls_ok, tls_time = tls_handshake(domain, 443, TLS_TIMEOUT)

    if not tls_ok:
        log.debug("TLS failed, retrying...")
        time.sleep(RETRY_DELAY)
        tls_ok, tls_time = tls_handshake(domain, 443, TLS_TIMEOUT)

    if not tls_ok:
        result.decision = "tunnel"
        result.block_type = "dpi"
        result.notes = "TLS handshake failed"
        log.info(domain + " -> tunnel (TLS blocked)")
        return result

    result.tls_time = tls_time

    if tls_time > SLOW_THRESHOLD:
        log.debug("TLS slow (" + str(round(tls_time, 3)) + "s), retrying")
        time.sleep(RETRY_DELAY)
        tls_ok2, tls_time2 = tls_handshake(domain, 443, TLS_TIMEOUT)
        if tls_ok2 and tls_time2 > SLOW_THRESHOLD:
            result.decision = "tunnel"
            result.block_type = "dpi"
            result.notes = "TLS slow on both attempts"
            log.info(domain + " -> tunnel (TLS slow x2)")
            return result
        if tls_ok2:
            result.tls_time = tls_time2

    # Шаг 3+4: HTTP проверка с анализом контента
    log.debug("HTTP check for " + domain)
    http = http_check(domain, 443, True, HTTP_TIMEOUT)

    if not http["ok"]:
        log.debug("HTTP failed, retrying...")
        time.sleep(RETRY_DELAY)
        http = http_check(domain, 443, True, HTTP_TIMEOUT)

    if not http["ok"]:
        result.decision = "tunnel"
        result.block_type = "dpi"
        result.notes = "HTTP failed: " + http.get("error", "")
        log.info(domain + " -> tunnel (HTTP failed)")
        return result

    result.http_status = http.get("status")
    location = http.get("location", "")
    content = http.get("content", "")

    if http.get("status") == 451:
        result.decision = "tunnel"
        result.block_type = "rkn"
        result.notes = "HTTP 451 Unavailable For Legal Reasons"
        log.info(domain + " -> tunnel (HTTP 451)")
        return result

    if is_blocked_redirect(location):
        result.decision = "tunnel"
        result.block_type = "geo-service"
        result.redirect_url = location
        result.notes = "Blocked redirect: " + location
        log.info(domain + " -> tunnel (redirect blocked: " + location + ")")
        return result

    if is_blocked_content(content):
        result.decision = "tunnel"
        result.block_type = "geo-service"
        result.notes = "Blocked content detected"
        log.info(domain + " -> tunnel (content blocked)")
        return result

    result.decision = "direct"
    result.notes = "All checks passed"
    log.info(domain + " -> direct (OK, status=" + str(result.http_status) + ")")
    return result
