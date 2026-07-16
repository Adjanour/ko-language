#!/bin/bash
# Build release binaries for Kō

set -e

echo "Building Kō release binaries..."

# Clean previous builds
rm -rf zig-out
rm -rf ko-dist/bin

# Build with ReleaseFast optimization
echo "Building ko (ReleaseFast)..."
zig build -Doptimize=ReleaseFast

# Create ko-dist/bin directory
mkdir -p ko-dist/bin

# Copy binaries
cp zig-out/bin/ko ko-dist/bin/ko
cp zig-out/bin/ko-lsp ko-dist/bin/ko-lsp

# Copy stdlib
cp -r std ko-dist/std

# Make binaries executable
chmod +x ko-dist/bin/ko
chmod +x ko-dist/bin/ko-lsp

echo "Release binaries built successfully!"
echo "  ko-dist/bin/ko      ($(du -h ko-dist/bin/ko | cut -f1))"
echo "  ko-dist/bin/ko-lsp  ($(du -h ko-dist/bin/ko-lsp | cut -f1))"
echo ""
echo "Test with: ./ko-dist/bin/ko --version"
