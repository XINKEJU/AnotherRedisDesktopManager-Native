#!/usr/bin/env python3
"""Scripted RESP server + driver for tests/core/probe.m.

Runs a fake Redis on two loopback ports (one of them also on ::1 so the client
can follow an IPv6 MOVED redirect), then launches the compiled probe against it
and reports the pass/fail counts.

Everything is deterministic: no real redis-server is required, so the suite runs
on any macOS machine and on CI. Compilation lives in tests/run.sh; this file only
serves and drives.
"""

import argparse
import os
import socket
import subprocess
import sys
import threading
import time

KEYS = [b"str:foo", b"hash:h", b"list:l"]
stop = threading.Event()


def bulk(b):
    return b"$" + str(len(b)).encode() + b"\r\n" + b + b"\r\n"


def simple(s):
    return b"+" + s + b"\r\n"


def integer(n):
    return b":" + str(n).encode() + b"\r\n"


def array(items):
    return b"*" + str(len(items)).encode() + b"\r\n" + b"".join(items)


def make_reply(port2):
    def reply(args):
        cmd = args[0].upper() if args else b""
        # Cluster redirection probes: force a MOVED so the client must follow it.
        if cmd == b"GET" and len(args) > 1:
            if args[1].startswith(b"redirect:"):
                return b"-MOVED 0 127.0.0.1:%d\r\n" % port2
            if args[1].startswith(b"ipv6:"):
                return b"-MOVED 0 [::1]:%d\r\n" % port2
        if cmd == b"PING":
            return simple(b"PONG")
        if cmd in (b"AUTH", b"CLIENT", b"SELECT", b"SET"):
            return simple(b"OK")
        if cmd == b"TYPE":
            return simple(b"string")
        if cmd == b"TTL":
            return integer(3600)
        if cmd == b"GET":
            return bulk(b"bar")
        if cmd == b"SCAN":
            return array([bulk(b"0"), array([bulk(k) for k in KEYS])])
        if cmd == b"HGETALL":
            return array([bulk(b"f1"), bulk(b"v1"), bulk(b"f2"), bulk(b"v2")])
        if cmd in (b"LRANGE", b"SMEMBERS", b"ZRANGE", b"XRANGE"):
            return array([bulk(b"a"), bulk(b"b")])
        if cmd == b"DBSIZE":
            return integer(3)
        if cmd == b"INFO":
            return bulk(b"# Server\r\nredis_version:7.0.0\r\n")
        if cmd in (b"SLOWLOG", b"MEMORY"):
            return array([bulk(b"peak.allocated"), integer(1024)])
        if cmd in (b"DEL", b"EXPIRE", b"PERSIST"):
            return integer(1)
        if cmd == b"CLUSTER" and len(args) > 1 and args[1].upper() == b"SLOTS":
            return array([array([integer(0), integer(16383),
                                 array([bulk(b"10.0.0.1"), integer(6379)])])])
        if cmd == b"CLUSTER" and len(args) > 1 and args[1].upper() == b"NODES":
            return bulk(b"node1 10.0.0.1:6379@16379 master - 0 0 1 connected 0-16383\n")
        if cmd in (b"HSCAN", b"SSCAN", b"ZSCAN", b"ARSCAN"):
            return array([bulk(b"0"), array([bulk(b"f1"), bulk(b"v1"),
                                             bulk(b"f2"), bulk(b"v2")])])
        if cmd == b"HTTL":
            return array([integer(60), integer(-1)])
        if cmd == b"PTTL":
            return integer(3600000)
        if cmd in (b"HEXPIRE", b"HPERSIST"):
            return array([integer(1)])
        if cmd == b"RESTORE":
            return simple(b"OK")
        if cmd in (b"VINFO", b"TS.INFO", b"ARINFO", b"XINFO", b"XPENDING", b"VSIM",
                   b"TS.REVRANGE", b"ARGREP", b"ARLEN", b"VRANGE", b"VRANDMEMBER"):
            return array([bulk(b"field"), bulk(b"value")])
        if cmd == b"UNLINK":
            return integer(len(args) - 1)
        if cmd in (b"HSET", b"HDEL", b"LSET", b"SADD", b"SREM", b"ZADD", b"XADD",
                   b"JSON.SET", b"RPUSH"):
            return simple(b"OK")
        # --- round 5 probes ---
        if cmd == b"BIGINT":
            return b":9223372036854775808\r\n"  # just past INT64_MAX
        if cmd in (b"LINSERT", b"LREM", b"HLEN", b"SCARD", b"VADD"):
            return integer(1)
        if cmd == b"CONFIG" and len(args) > 1 and args[1].upper() == b"GET":
            return array([bulk(b"slowlog-log-slower-than"), integer(10000),
                          bulk(b"slowlog-max-len"), integer(128)])
        if cmd == b"XREVRANGE":
            return array([array([bulk(b"2-0"), array([bulk(b"f"), bulk(b"v")])])])
        if cmd == b"TS.RANGE":
            return array([array([integer(1000), bulk(b"1.5")])])
        if cmd == b"VGETATTR":
            return bulk(b"[0.1,0.2]")
        return b"-ERR unknown command\r\n"
    return reply


def read_command(f):
    line = f.readline()
    if not line or not line.startswith(b"*"):
        return None
    count = int(line[1:-2])
    args = []
    for _ in range(count):
        header = f.readline()
        size = int(header[1:-2])
        args.append(f.read(size))
        f.read(2)
    return args


def handle(conn, reply):
    f = conn.makefile("rb")
    in_multi = False
    queued = 0
    # Per-connection command log. PROBE.SEQ returns it so the probe can assert
    # ordering (e.g. that no PING landed between MULTI and EXEC).
    seq = []
    try:
        while not stop.is_set():
            args = read_command(f)
            if args is None:
                break
            head = args[0].upper() if args else b""
            if head == b"PROBE.SEQ":
                conn.sendall(array([bulk(x.encode()) for x in seq]))
                continue
            seq.append(head.decode("ascii", "replace"))
            if head == b"MULTI":
                in_multi = True
                queued = 0
                conn.sendall(simple(b"OK"))
                continue
            if head == b"EXEC":
                in_multi = False
                conn.sendall(array([simple(b"OK") for _ in range(queued)]))
                queued = 0
                continue
            if head == b"DISCARD":
                in_multi = False
                queued = 0
                conn.sendall(simple(b"OK"))
                continue
            if in_multi:
                # SLOW widens the window between MULTI and EXEC so a racy client
                # has a real chance to slip another command in.
                if head == b"SLOW":
                    time.sleep(0.3)
                queued += 1
                conn.sendall(simple(b"QUEUED"))
                continue
            if head == b"SUBSCRIBE":
                conn.sendall(array([bulk(b"subscribe"), bulk(b"channel"), integer(1)]))
                time.sleep(0.05)
                conn.sendall(array([bulk(b"message"), bulk(b"channel"), bulk(b"hello")]))
                continue
            if head == b"MONITOR":
                conn.sendall(simple(b"OK"))
                time.sleep(0.05)
                conn.sendall(bulk(b'1600000000.000000 [0 127.0.0.1:1] "GET" "foo"'))
                continue
            conn.sendall(reply(args))
    except (OSError, ValueError):
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


def serve(port, reply, extra_family=None):
    sockets = []
    try:
        s = socket.socket()
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", port))
        s.listen(8)
        s.settimeout(0.3)
        sockets.append(s)
    except OSError as exc:
        print(f"cannot bind 127.0.0.1:{port}: {exc}", file=sys.stderr)
        sys.exit(1)
    if extra_family:  # also bind ::1 so an IPv6 MOVED target resolves
        try:
            s6 = socket.socket(extra_family, socket.SOCK_STREAM)
            s6.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s6.bind(("::1", port))
            s6.listen(4)
            s6.settimeout(0.3)
            sockets.append(s6)
        except OSError:
            pass
    while not stop.is_set():
        for sock in sockets:
            try:
                conn, _ = sock.accept()
            except socket.timeout:
                continue
            threading.Thread(target=handle, args=(conn, reply), daemon=True).start()
    for sock in sockets:
        sock.close()


def cross_node_reply(args):
    cmd = args[0].upper() if args else b""
    if cmd == b"PING":
        return simple(b"PONG")
    if cmd == b"GET":
        return bulk(b"cross-node-ok")
    return simple(b"OK")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--probe", required=True, help="compiled probe binary")
    parser.add_argument("--root", required=True, help="project root (src/ lives here)")
    parser.add_argument("--port", type=int, default=16379)
    parser.add_argument("--port2", type=int, default=16380)
    args = parser.parse_args()

    threading.Thread(target=serve, args=(args.port, make_reply(args.port2)), daemon=True).start()
    threading.Thread(target=serve, args=(args.port2, cross_node_reply, socket.AF_INET6),
                     daemon=True).start()

    env = dict(os.environ, ARDM_PROJECT_ROOT=args.root)
    print("=== running the native client against the fake RESP server ===", flush=True)
    try:
        result = subprocess.run([args.probe, str(args.port)], capture_output=True,
                                text=True, env=env, cwd=args.root, timeout=180)
    finally:
        stop.set()
    print(result.stdout)
    if result.stderr:
        print("stderr:", result.stderr[:800])
    failures = result.stdout.count("[FAIL]")
    passes = result.stdout.count("[PASS]")
    print(f"=== core: {passes} passed, {failures} failed ===")
    return 1 if failures or result.returncode else 0


if __name__ == "__main__":
    sys.exit(main())
