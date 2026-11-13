#!/bin/bash
# Regression suite for the native ARDM core and updater.
#
#   bash tests/run.sh            # everything
#   bash tests/run.sh core       # RESP client / formatters / localization / keychain
#   bash tests/run.sh updater    # SHA-256, checksum parsing, signature, atomic swap
#
# Neither suite needs a redis-server, a GUI session, or a full Xcode install —
# only the Command Line Tools (clang) and python3. That is what makes them usable
# in CI. The suites compile the real sources (Redis.m, Services.m, Transport.m),
# so a break in the transport layer fails here before it reaches the .app.
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

if ! command -v clang >/dev/null || ! command -v python3 >/dev/null; then
    echo "ERROR: clang and python3 are required (xcode-select --install)." >&2
    exit 1
fi

mkdir -p "$BUILD"
CORE_OK=0
UPDATER_OK=0

compile_core() {
    echo "=== [core] compiling the probe against Redis.m / Services.m / Transport.m ==="
    # shellcheck disable=SC2086
    clang -fobjc-arc -O2 -I "$ROOT" \
        -Wno-deprecated-declarations -Wno-nullability-completeness \
        -framework AppKit -framework Foundation -framework JavaScriptCore \
        -framework Security -framework Network -framework WebKit -lz \
        "$ROOT/Redis.m" "$ROOT/Services.m" "$ROOT/Transport.m" \
        "$HERE/core/probe.m" \
        -o "$BUILD/core-probe"
}

run_core() {
    if ! compile_core; then
        echo "=== core: COMPILE FAILED ===" >&2
        return 1
    fi
    python3 "$HERE/core/fake_redis.py" --probe "$BUILD/core-probe" --root "$PROJECT"
}

compile_updater() {
    echo "=== [updater] compiling Redis/Services objects and the updater probe ==="
    for source in Redis.m Services.m; do
        clang -fobjc-arc -O2 -I "$ROOT" -Wno-deprecated-declarations \
            -c "$ROOT/$source" -o "$BUILD/${source%.m}.o" || return 1
    done
    clang -fobjc-arc -O1 -I "$ROOT" -Wno-deprecated-declarations \
        -Wno-nullability-completeness \
        "$HERE/updater/probe.m" "$BUILD/Redis.o" "$BUILD/Services.o" \
        -framework AppKit -framework JavaScriptCore -framework Security \
        -framework Network -framework WebKit -lz \
        -o "$BUILD/updater-probe"
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
