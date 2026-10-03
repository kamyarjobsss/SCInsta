#!/usr/bin/env bash
# Build the in-process Xray core as an iOS arm64 static archive.
# Requires macOS, Xcode's iPhoneOS SDK, and Go 1.26+.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/ixray"
OUT="$SRC/libixray.a"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "build_ixray.sh: skipping (needs macOS / iPhoneOS SDK)"
    exit 1
fi

if ! command -v go >/dev/null 2>&1; then
    echo "build_ixray.sh: go is not installed"
    exit 1
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MIN_FLAG="-miphoneos-version-min=15.0"
FLAGS="-isysroot ${SDK} ${MIN_FLAG} -arch arm64"

export GOOS=ios
export GOARCH=arm64
export CGO_ENABLED=1
export CC="xcrun --sdk iphoneos --toolchain iphoneos clang"
export CXX="xcrun --sdk iphoneos --toolchain iphoneos clang++"
export CGO_CFLAGS="${FLAGS}"
export CGO_CXXFLAGS="${FLAGS}"
export CGO_LDFLAGS="${FLAGS} -Wl,-Bsymbolic-functions"
export GOFLAGS="-tags=ios"
export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}"

cd "$SRC"
go mod tidy
go build -trimpath -ldflags "-s -w -buildid=" -buildmode=c-archive -o "$OUT" .

test -f "$OUT"
test -f "$SRC/libixray.h"
echo "Built $OUT"
ls -lh "$OUT"
