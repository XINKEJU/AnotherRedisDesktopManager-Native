#!/bin/bash
# Regression suite for the native ARDM core and updater.
#
#   bash tests/run.sh            # everything
#   bash tests/run.sh core       # RESP client / formatters / localization / keychain
#   bash tests/run.sh updater    # SHA-256, checksum parsing, signature, atomic swap
#
# Neither suite needs a redis-server, a GUI session, or a full Xcode install —
# only the Command Line Tools and python3. That is what makes them usable in CI.
# The suites compile the real Swift sources, so a break in the transport layer
# fails here before it reaches the .app.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"          # native/
PROJECT="$(cd "$ROOT/.." && pwd)"       # repo root (src/ lives here)
BUILD="$HERE/.build"
WHICH="${1:-all}"

if [[ "$WHICH" != "all" && "$WHICH" != "core" && "$WHICH" != "updater" ]]; then
    echo "usage: $0 [all|core|updater]" >&2
    exit 2
fi

if ! command -v swiftc >/dev/null || ! command -v python3 >/dev/null; then
    echo "ERROR: swiftc (Xcode command line tools) and python3 are required." >&2
    exit 1
fi

mkdir -p "$BUILD"
CORE_OK=0
UPDATER_OK=0

swift_compile() {
    local output="$1"
    shift
    xcrun swiftc -O \
        "$@" \
        -framework AppKit -framework CoreFoundation -framework JavaScriptCore \
        -framework Security -framework Network -framework WebKit -lz \
        -o "$output"
}

compile_core() {
    echo "=== [core] compiling the probe against the Swift core ==="
    # The UI label tables ride along so the localization priority chain
    # (curated table -> upstream text -> word-wise hybrid) is really covered.
    swift_compile "$BUILD/core-probe" \
        "$ROOT/swift/AppServices.swift" "$ROOT/swift/Formatters.swift" \
        "$ROOT/swift/Deserializers.swift" "$ROOT/swift/Localization.swift" \
        "$ROOT/swift/UILocalization.swift" "$ROOT/swift/UILabels.swift" \
        "$ROOT/swift/ConnectionConfig.swift" "$ROOT/swift/Keychain.swift" \
        "$ROOT/swift/RedisClient.swift" \
        "$HERE/core/main.swift"
}

run_core() {
    if ! compile_core; then
        echo "=== core: COMPILE FAILED ===" >&2
        return 1
    fi
    python3 "$HERE/core/fake_redis.py" --probe "$BUILD/core-probe" --root "$PROJECT"
}

compile_updater() {
    echo "=== [updater] compiling the Swift updater core and probe ==="
    swift_compile "$BUILD/updater-probe" \
        "$ROOT/swift/AppServices.swift" \
        "$ROOT/swift/ConnectionConfig.swift" "$ROOT/swift/Keychain.swift" \
        "$HERE/updater/main.swift"
}

run_updater() {
    if ! compile_updater; then
        echo "=== updater: COMPILE FAILED ===" >&2
        return 1
    fi
    # Prefer the real build so the signature checks run against what ships;
    # fall back to a generated fixture on machines that never ran build.sh.
    local app="$ROOT/ARDM Native.app"
    if [[ ! -d "$app" ]]; then
        app="$BUILD/Fixture.app"
        bash "$HERE/updater/fixture.sh" "$app" || return 1
    fi
    "$BUILD/updater-probe" "$app"
}

if [[ "$WHICH" == "all" || "$WHICH" == "core" ]]; then
    run_core && CORE_OK=1
    echo
fi
if [[ "$WHICH" == "all" || "$WHICH" == "updater" ]]; then
    run_updater && UPDATER_OK=1
    echo
fi

echo "=== summary ==="
fail=0
if [[ "$WHICH" == "all" || "$WHICH" == "core" ]]; then
    echo "  core    : $([[ $CORE_OK == 1 ]] && echo PASS || echo FAIL)"
    [[ $CORE_OK == 1 ]] || fail=1
fi
if [[ "$WHICH" == "all" || "$WHICH" == "updater" ]]; then
    echo "  updater : $([[ $UPDATER_OK == 1 ]] && echo PASS || echo FAIL)"
    [[ $UPDATER_OK == 1 ]] || fail=1
fi
exit $fail
