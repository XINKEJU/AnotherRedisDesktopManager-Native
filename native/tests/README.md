# Native test suite

Two self-contained suites that compile the real Swift sources and drive them
without a GUI, a `redis-server`, or a full Xcode install (swiftc + python3
only). CI runs them via `.github/workflows/native.yml`.

```bash
bash native/tests/run.sh            # both suites (108 assertions)
bash native/tests/run.sh core       # 93 assertions
bash native/tests/run.sh updater    # 15 assertions
```

Exit status is non-zero if anything fails, so it drops straight into CI.

## core/ — 93 assertions

`fake_redis.py` starts a scripted RESP server on 127.0.0.1:16379 (plus 16380 on
`::1` so an IPv6 `MOVED` target resolves), then runs the Swift probe
(`core/main.swift`) against it. The probe is compiled together with the Swift
core under test.

Covers: connect/PING, bulk strings, SCAN cursors, TTL/PTTL, INFO, DBSIZE, binary
arguments (`NSData`), read-only mode blocking writes and two-token admin commands
(`CONFIG SET`, `CLIENT KILL`, `HEXPIRE`, `RESTORE`), `MULTI`/`EXEC`, HSCAN
streaming, MOVED redirects (IPv4 and IPv6), AUTH masking, all 15 viewers
(render + 12 write-back paths), Msgpack/PHP/Protobuf/Gzip/Deflate round-trips,
Protobuf nested messages and repeated fields, OverSize paging, Java/Pickle
readers, viewer auto-detection, big-integer preservation in JSON, JSON
validation, localization (13 languages, 12 tables resolving), command reference,
custom formatter persistence, security-scoped bookmarks, Keychain storage and
redaction, and the plaintext→Keychain migration counter.

## updater/ — 15 assertions

`updater/main.swift` is compiled together with `swift/AppServices.swift` so the
internal helpers (SHA-256, checksum parsing, signature inspection, atomic bundle
swap) can be called directly.

Covers: SHA-256 agreeing with `shasum`, four checksum-file layouts, strict
signature validation of a real bundle, a tampered bundle being rejected
(-67054), swap keeping the previous version as `.previous`, a read-only
destination being refused without leaving files behind, a foreign bundle id
being refused, a digest mismatch aborting before install, and `/Applications`
staying untouched through both refusals.

The signature tests need a sealed `.app`. `run.sh` passes the real build when
`native/ARDM Native.app` exists, otherwise it generates an ad-hoc-signed fixture
via `updater/fixture.sh`.

## Deliberately not covered

The suites are headless, so SwiftUI layout, menus, and the two-step update
confirmation dialog are not exercised — those need a GUI session and are checked
by hand before a release.
