#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KO_DIR="$SCRIPT_DIR/ko-zig"
DIST_DIR="$SCRIPT_DIR/ko-dist"

echo "Building Kō compiler..."

# Check for Zig
if ! command -v zig &> /dev/null; then
    echo "Error: zig not found. Install Zig 0.17 from https://ziglang.org/download/"
    exit 1
fi

ZIG_VERSION=$(zig version 2>/dev/null | head -1)
echo "Found zig: $ZIG_VERSION"

# Build
cd "$KO_DIR"
zig build

if [ ! -f zig-out/bin/ko ]; then
    echo "Build failed!"
    exit 1
fi

# Create dist folder
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR/bin"
mkdir -p "$DIST_DIR/std"

# Copy binary
cp "$KO_DIR/zig-out/bin/ko" "$DIST_DIR/bin/ko"

# Copy stdlib
cp "$KO_DIR/std/"*.ko "$DIST_DIR/std/"

# Copy examples (optional, nice to have)
mkdir -p "$DIST_DIR/examples"
cp "$KO_DIR/examples/"*.ko "$DIST_DIR/examples/" 2>/dev/null || true

# Create a symlink at top level for convenience
ln -sf bin/ko "$DIST_DIR/ko"

echo ""
echo "Built: $DIST_DIR/"
echo ""
echo "Contents:"
echo "  bin/ko          - compiler binary"
echo "  std/            - standard library"
echo "  examples/       - example programs"
echo "  ko -> bin/ko    - convenience symlink"
echo ""
echo "Try it:"
echo "  echo 'fn main = println \"Hello, Kō!\"' > /tmp/hello.ko"
echo "  $DIST_DIR/ko /tmp/hello.ko"
echo ""
echo "Move it anywhere:"
echo "  cp -r $DIST_DIR ~/ko"
echo "  ~/ko/ko some_program.ko"
