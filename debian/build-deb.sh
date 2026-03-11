#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build/flutter-pi/aarch64-generic"
VERSION=$(grep '^Version:' "$SCRIPT_DIR/control" | awk '{print $2}')
PKG_NAME="rustyfoot-hmi_${VERSION}_arm64"
STAGE_DIR="$PROJECT_DIR/build/$PKG_NAME"

if [ ! -d "$BUILD_DIR" ]; then
    echo "Build directory not found: $BUILD_DIR"
    echo "Run 'flutterpi_tool build --release --arch=arm64' first."
    exit 1
fi

echo "Staging package $PKG_NAME..."

rm -rf "$STAGE_DIR"

# Control files
mkdir -p "$STAGE_DIR/DEBIAN"
cp "$SCRIPT_DIR/control" "$STAGE_DIR/DEBIAN/control"
cp "$SCRIPT_DIR/postinst" "$STAGE_DIR/DEBIAN/postinst"
cp "$SCRIPT_DIR/prerm" "$STAGE_DIR/DEBIAN/prerm"
cp "$SCRIPT_DIR/postrm" "$STAGE_DIR/DEBIAN/postrm"
chmod 755 "$STAGE_DIR/DEBIAN/postinst" "$STAGE_DIR/DEBIAN/prerm" "$STAGE_DIR/DEBIAN/postrm"

# Application bundle
mkdir -p "$STAGE_DIR/usr/lib/rustyfoot-hmi"
cp -a "$BUILD_DIR"/. "$STAGE_DIR/usr/lib/rustyfoot-hmi/"

# Wrapper script
mkdir -p "$STAGE_DIR/usr/bin"
cp "$SCRIPT_DIR/rustyfoot-hmi.sh" "$STAGE_DIR/usr/bin/rustyfoot-hmi"
chmod 755 "$STAGE_DIR/usr/bin/rustyfoot-hmi"

# Systemd service
mkdir -p "$STAGE_DIR/lib/systemd/system"
cp "$SCRIPT_DIR/rustyfoot-hmi.service" "$STAGE_DIR/lib/systemd/system/"

# ld.so config for libflutter_engine.so
mkdir -p "$STAGE_DIR/etc/ld.so.conf.d"
cp "$SCRIPT_DIR/rustyfoot-hmi.conf" "$STAGE_DIR/etc/ld.so.conf.d/"

# Calculate installed size (in KB)
SIZE=$(du -sk "$STAGE_DIR" | awk '{print $1}')
sed -i "/^Architecture:/a Installed-Size: $SIZE" "$STAGE_DIR/DEBIAN/control"

echo "Building .deb..."
dpkg-deb --root-owner-group --build "$STAGE_DIR" "$PROJECT_DIR/build/$PKG_NAME.deb"

echo "Built: build/$PKG_NAME.deb"
