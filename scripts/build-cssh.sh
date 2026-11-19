#!/bin/bash
# Builds Packages/CameraKit/CSSH.xcframework: libssh2 1.11.1 + OpenSSL 3.5.9 (static), and a zip of it with the zip's
# checksum, the form Package.swift's CSSH target takes from a release by URL.
# Slices: ios-arm64, ios-arm64_x86_64-simulator, macos-arm64_x86_64.
# Usage: bash scripts/build-cssh.sh
# Requires: Xcode command-line tools, make, perl (all shipped with Xcode).

set -euo pipefail

LIBSSH2_VERSION=1.11.1
OPENSSL_VERSION=3.5.9
LIBSSH2_SHA256=d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a

LIBSSH2_URL=https://github.com/libssh2/libssh2/releases/download/libssh2-${LIBSSH2_VERSION}/libssh2-${LIBSSH2_VERSION}.tar.gz
OPENSSL_URL=https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
CLANG=$(xcrun --find clang)
BUILD_THREADS=$(sysctl -n hw.ncpu)

REPO_ROOT="$(cd "$(dirname "$0")/.."; pwd)"
DEST="$REPO_ROOT/Packages/CameraKit/CSSH.xcframework"

WORK="${TMPDIR:-/tmp}/cssh-build-$$"
mkdir -p "$WORK/src/openssl" "$WORK/src/libssh2"
trap 'rm -rf "$WORK"' EXIT

fetch_and_verify() {
    local URL="$1" FILE="$2" EXPECTED_SHA="$3"
    echo "Fetching $(basename "$FILE")..."
    curl -sL "$URL" -o "$FILE"
    local ACTUAL
    ACTUAL=$(shasum -a 256 "$FILE" | awk '{print $1}')
    if [[ "$ACTUAL" != "$EXPECTED_SHA" ]]; then
        echo "SHA-256 mismatch for $(basename "$FILE")"
        echo "  expected: $EXPECTED_SHA"
        echo "  actual:   $ACTUAL"
        exit 1
    fi
    echo "  verified $ACTUAL"
}

fetch_and_verify "$LIBSSH2_URL" "$WORK/libssh2.tar.gz" "$LIBSSH2_SHA256"
fetch_and_verify "$OPENSSL_URL" "$WORK/openssl.tar.gz" "$OPENSSL_SHA256"

tar -xzf "$WORK/openssl.tar.gz"  -C "$WORK/src/openssl"  --strip-components=1
tar -xzf "$WORK/libssh2.tar.gz"  -C "$WORK/src/libssh2"  --strip-components=1

MODULE_MAP="$WORK/module.modulemap"
cat > "$MODULE_MAP" <<'EOF'
module CSSH {
    header "libssh2.h"
    header "libssh2_sftp.h"
    header "libssh2_publickey.h"
    export *
}
EOF

# OpenSSL compiles in where it looks for its configuration, engines and modules. /var/empty is empty and only root can
# write to it, so nothing on a device or a Mac changes how the app's OpenSSL behaves, and no path on the machine that
# built it ends up in the app. It's installed under OUT, at OUT/var/empty.
build_openssl() {
    local OUT="$1" TARGET="$2" MIN_FLAG="${3:-}"
    if [[ -f "$OUT/var/empty/lib/libssl.a" ]]; then return; fi
    mkdir -p "$OUT"
    local WD="$OUT/openssl-work"
    cp -R "$WORK/src/openssl" "$WD"
    pushd "$WD" > /dev/null
    ./Configure "$TARGET" no-shared no-apps no-tests no-docs \
        enable-ec_nistp_64_gcc_128 \
        --prefix=/var/empty --openssldir=/var/empty $MIN_FLAG >> "$OUT/openssl.log" 2>&1
    make -j "$BUILD_THREADS" build_sw  >> "$OUT/openssl.log" 2>&1
    make install_sw DESTDIR="$OUT"     >> "$OUT/openssl.log" 2>&1
    popd > /dev/null
    rm -rf "$WD"
}

build_libssh2() {
    local OUT="$1" OSSL="$2" ARCH="$3" HOST="$4" MIN_FLAG="$5" SDK="$6"
    if [[ -f "$OUT/lib/libssh2.a" ]]; then return; fi
    mkdir -p "$OUT"
    local WD="$OUT/libssh2-work"
    cp -R "$WORK/src/libssh2" "$WD"
    pushd "$WD" > /dev/null
    env CC="$CLANG" \
        CFLAGS="-O2 -arch $ARCH -isysroot $SDK $MIN_FLAG" \
        CPPFLAGS="-arch $ARCH -isysroot $SDK $MIN_FLAG" \
        ./configure \
            --host="$HOST" --prefix="$OUT" \
            --disable-debug --disable-dependency-tracking \
            --disable-silent-rules --disable-examples-build \
            --without-libz --with-crypto=openssl \
            --with-libssl-prefix="$OSSL" \
            --disable-shared --enable-static >> "$OUT/libssh2.log" 2>&1
    make -j "$BUILD_THREADS" >> "$OUT/libssh2.log" 2>&1
    make install              >> "$OUT/libssh2.log" 2>&1
    popd > /dev/null
    rm -rf "$WD"
}

IOS_SDK=$(xcrun --sdk iphoneos       --show-sdk-path)
SIM_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
MAC_SDK=$(xcrun --sdk macosx         --show-sdk-path)

echo "Building OpenSSL $OPENSSL_VERSION..."
build_openssl "$WORK/out/ios-arm64/openssl"   "ios64-xcrun"               "-miphoneos-version-min=17.0"
build_openssl "$WORK/out/sim-arm64/openssl"   "iossimulator-arm64-xcrun"  "-miphonesimulator-version-min=17.0"
build_openssl "$WORK/out/sim-x86_64/openssl"  "iossimulator-x86_64-xcrun" "-miphonesimulator-version-min=17.0"
build_openssl "$WORK/out/mac-arm64/openssl"   "darwin64-arm64"            "-mmacosx-version-min=14.0"
build_openssl "$WORK/out/mac-x86_64/openssl"  "darwin64-x86_64"           "-mmacosx-version-min=14.0"

echo "Building libssh2 $LIBSSH2_VERSION..."
build_libssh2 "$WORK/out/ios-arm64/ssh2" "$WORK/out/ios-arm64/openssl/var/empty" \
    "arm64" "aarch64-apple-darwin" "-miphoneos-version-min=17.0" "$IOS_SDK"
build_libssh2 "$WORK/out/sim-arm64/ssh2" "$WORK/out/sim-arm64/openssl/var/empty" \
    "arm64" "aarch64-apple-darwin" "-miphonesimulator-version-min=17.0" "$SIM_SDK"
build_libssh2 "$WORK/out/sim-x86_64/ssh2" "$WORK/out/sim-x86_64/openssl/var/empty" \
    "x86_64" "x86_64-apple-darwin" "-miphonesimulator-version-min=17.0" "$SIM_SDK"
build_libssh2 "$WORK/out/mac-arm64/ssh2" "$WORK/out/mac-arm64/openssl/var/empty" \
    "arm64" "aarch64-apple-darwin" "-mmacosx-version-min=14.0" "$MAC_SDK"
build_libssh2 "$WORK/out/mac-x86_64/ssh2" "$WORK/out/mac-x86_64/openssl/var/empty" \
    "x86_64" "x86_64-apple-darwin" "-mmacosx-version-min=14.0" "$MAC_SDK"

echo "Merging..."
mkdir -p "$WORK/libs/ios-arm64" "$WORK/libs/sim-fat" "$WORK/libs/mac-fat"

libtool -static -D -o "$WORK/libs/ios-arm64/libssh2.a" \
    "$WORK/out/ios-arm64/ssh2/lib/libssh2.a" \
    "$WORK/out/ios-arm64/openssl/var/empty/lib/libssl.a" \
    "$WORK/out/ios-arm64/openssl/var/empty/lib/libcrypto.a"

for ARCH in arm64 x86_64; do
    libtool -static -D -o "$WORK/libs/sim-$ARCH.a" \
        "$WORK/out/sim-$ARCH/ssh2/lib/libssh2.a" \
        "$WORK/out/sim-$ARCH/openssl/var/empty/lib/libssl.a" \
        "$WORK/out/sim-$ARCH/openssl/var/empty/lib/libcrypto.a"
done
lipo -create "$WORK/libs/sim-arm64.a" "$WORK/libs/sim-x86_64.a" -output "$WORK/libs/sim-fat/libssh2.a"

for ARCH in arm64 x86_64; do
    libtool -static -D -o "$WORK/libs/mac-$ARCH.a" \
        "$WORK/out/mac-$ARCH/ssh2/lib/libssh2.a" \
        "$WORK/out/mac-$ARCH/openssl/var/empty/lib/libssl.a" \
        "$WORK/out/mac-$ARCH/openssl/var/empty/lib/libcrypto.a"
done
lipo -create "$WORK/libs/mac-arm64.a" "$WORK/libs/mac-x86_64.a" -output "$WORK/libs/mac-fat/libssh2.a"

for SLICE in ios-arm64 sim-fat mac-fat; do
    mkdir -p "$WORK/libs/$SLICE/Headers"
    cp "$WORK/out/ios-arm64/ssh2/include/libssh2"*.h "$WORK/libs/$SLICE/Headers/"
    cp "$MODULE_MAP" "$WORK/libs/$SLICE/Headers/"
done

echo "Creating xcframework..."
rm -rf "$DEST"
xcodebuild -create-xcframework \
    -library "$WORK/libs/ios-arm64/libssh2.a"  -headers "$WORK/libs/ios-arm64/Headers" \
    -library "$WORK/libs/sim-fat/libssh2.a"    -headers "$WORK/libs/sim-fat/Headers" \
    -library "$WORK/libs/mac-fat/libssh2.a"    -headers "$WORK/libs/mac-fat/Headers" \
    -output "$DEST"

ZIP_OUT="${TMPDIR:-/tmp}/CSSH-${LIBSSH2_VERSION}-OpenSSL-${OPENSSL_VERSION}.xcframework.zip"
rm -f "$ZIP_OUT"
(cd "$(dirname "$DEST")" && zip -qrX --symlinks "$ZIP_OUT" "$(basename "$DEST")")
CHECKSUM=$(swift package compute-checksum "$ZIP_OUT")

echo ""
echo "Built: libssh2 $LIBSSH2_VERSION + OpenSSL $OPENSSL_VERSION"
echo "xcframework: $DEST"
echo "zip:         $ZIP_OUT"
echo "checksum:    $CHECKSUM"
