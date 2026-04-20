#!/usr/bin/env python3
import sys
import os
import time

sys.path.insert(0, '/usr/local/bin/smart-proxy')
import db
import tester

DB_PATH = '/var/lib/smart-proxy/cache.db'

def usage():
    print("Usage: smart-proxy-ctl <command> [args]")
    print("")
    print("Commands:")
    print("  add-tunnel <domain> [reason]  Force domain through tunnel")
    print("  add-direct <domain> [reason]  Force domain to direct")
    print("  remove <domain>               Remove manual override")
    print("  recheck <domain>              Re-test domain and update cache")
    print("  status <domain>               Show domain routing decision")
    print("  list manual                   Show all manual overrides")
    print("  list tunnel                   Show cached tunnel domains")
    print("  list direct                   Show cached direct domains")
    print("  stats                         Show cache statistics")

def cmd_add_tunnel(args):
    if not args:
        print("Error: domain required")
        sys.exit(1)
    domain = args[0].lower().strip()
    reason = args[1] if len(args) > 1 else None
    db.save_manual(domain, "tunnel", reason)
    db.delete_cached(domain)
    print("OK: " + domain + " -> tunnel (manual)")

def cmd_add_direct(args):
    if not args:
        print("Error: domain required")
        sys.exit(1)
    domain = args[0].lower().strip()
    reason = args[1] if len(args) > 1 else None
    db.save_manual(domain, "direct", reason)
    db.delete_cached(domain)
    print("OK: " + domain + " -> direct (manual)")

def cmd_remove(args):
    if not args:
        print("Error: domain required")
        sys.exit(1)
    domain = args[0].lower().strip()
    removed = db.remove_manual(domain)
    cached = db.delete_cached(domain)
    if removed or cached:
        print("OK: " + domain + " removed from overrides and cache")
    else:
        print("Not found: " + domain)

def cmd_recheck(args):
    if not args:
        print("Error: domain required")
        sys.exit(1)
    domain = args[0].lower().strip()
    db.remove_manual(domain)
    db.delete_cached(domain)
    print("Testing " + domain + "...")
    result = tester.test_domain(domain)
    db.save(
        domain, result.decision, "manual-recheck",
        block_type=result.block_type,
        tcp_time=result.tcp_time,
        tls_time=result.tls_time,
        http_status=result.http_status,
        redirect_url=result.redirect_url,
        notes=result.notes
    )
    print("Result: " + domain + " -> " + result.decision)
    print("  block_type : " + str(result.block_type))
    print("  port       : " + str(result.port_used))
    print("  tcp_time   : " + str(round(result.tcp_time, 3) if result.tcp_time else None))
    print("  tls_time   : " + str(round(result.tls_time, 3) if result.tls_time else None))
    print("  http_status: " + str(result.http_status))
    print("  redirect   : " + str(result.redirect_url))
    print("  notes      : " + str(result.notes))

def cmd_status(args):
    if not args:
        print("Error: domain required")
        sys.exit(1)
    domain = args[0].lower().strip()
    manual = db.get_manual(domain)
    if manual:
        print(domain + " -> " + manual["decision"] + " [MANUAL]")
        print("  reason: " + str(manual["reason"]))
        return
    cached = db.get(domain)
    if cached:
        print(domain + " -> " + cached["decision"] + " [" + cached["source"] + "]")
        print("  block_type : " + str(cached["block_type"]))
        print("  http_status: " + str(cached["http_status"]))
        print("  tcp_time   : " + str(cached["tcp_time"]))
        print("  notes      : " + str(cached["notes"]))
    else:
        print(domain + " -> not in cache (will be tested on first access)")

def cmd_list(args):
    if not args:
        print("Error: list manual|tunnel|direct")
        sys.exit(1)
    what = args[0]
    if what == "manual":
        rows = db.list_manual()
        if not rows:
            print("No manual overrides")
            return
        print("Manual overrides (" + str(len(rows)) + "):")
        for r in rows:
            ts = time.strftime("%Y-%m-%d %H:%M", time.localtime(r["added_at"]))
            reason = (" | " + r["reason"]) if r["reason"] else ""
            print("  " + r["domain"] + " -> " + r["decision"] + " | " + ts + reason)
    elif what in ("tunnel", "direct"):
        sources = ["auto-test", "startup-test", "manual-recheck"]
        rows = []
        for src in sources:
            rows += db.list_by_source(src)
        filtered = [r for r in rows if r["decision"] == what]
        if not filtered:
            print("No cached " + what + " domains")
            return
        print("Cached " + what + " domains (" + str(len(filtered)) + "):")
        for r in filtered:
            print("  " + r["domain"] + " [" + str(r["block_type"]) + "]")
    else:
        print("Error: list manual|tunnel|direct")

def cmd_stats(args):
    s = db.stats()
    print("Cache statistics:")
    print("  total  : " + str(s.get("total", 0)))
    print("  direct : " + str(s.get("direct", 0)))
    print("  tunnel : " + str(s.get("tunnel", 0)))
    print("  manual : " + str(s.get("manual", 0)))

def main():
    db.init(DB_PATH)
    if len(sys.argv) < 2:
        usage()
        sys.exit(0)
    cmd = sys.argv[1]
    args = sys.argv[2:]
    commands = {
        "add-tunnel": cmd_add_tunnel,
        "add-direct": cmd_add_direct,
        "remove": cmd_remove,
        "recheck": cmd_recheck,
        "status": cmd_status,
        "list": cmd_list,
        "stats": cmd_stats,
    }
    if cmd not in commands:
        print("Unknown command: " + cmd)
        usage()
        sys.exit(1)
    commands[cmd](args)

if __name__ == "__main__":
    main()
