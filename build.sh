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
mkdir -p "$DIST_DIR"

# Copy binaries directly into dist (no bin/ subdirectory)
cp "$KO_DIR/zig-out/bin/ko" "$DIST_DIR/ko"
cp "$KO_DIR/zig-out/bin/ko-lsp" "$DIST_DIR/ko-lsp" 2>/dev/null || true

# Copy stdlib
cp -r "$KO_DIR/std" "$DIST_DIR/std"

# Copy examples
mkdir -p "$DIST_DIR/examples"
cp "$KO_DIR/examples/"*.ko "$DIST_DIR/examples/" 2>/dev/null || true

# Copy VS Code extension
mkdir -p "$DIST_DIR/editors/vscode"
cp "$SCRIPT_DIR/vscode-ko/package.json" "$DIST_DIR/editors/vscode/"
cp "$SCRIPT_DIR/vscode-ko/extension.js" "$DIST_DIR/editors/vscode/"
cp "$SCRIPT_DIR/vscode-ko/language-configuration.json" "$DIST_DIR/editors/vscode/"
mkdir -p "$DIST_DIR/editors/vscode/syntaxes"
cp "$SCRIPT_DIR/vscode-ko/syntaxes/"*.json "$DIST_DIR/editors/vscode/syntaxes/" 2>/dev/null || true
cp "$SCRIPT_DIR/vscode-ko/icon.png" "$DIST_DIR/editors/vscode/" 2>/dev/null || true

# Copy tree-sitter grammar
mkdir -p "$DIST_DIR/editors/tree-sitter"
cp "$SCRIPT_DIR/tree-sitter-ko/grammar.js" "$DIST_DIR/editors/tree-sitter/"
cp "$SCRIPT_DIR/tree-sitter-ko/package.json" "$DIST_DIR/editors/tree-sitter/"
cp -r "$SCRIPT_DIR/tree-sitter-ko/queries" "$DIST_DIR/editors/tree-sitter/"

# Copy docs
mkdir -p "$DIST_DIR/docs"
cp "$SCRIPT_DIR/docs/quick-reference.md" "$DIST_DIR/docs/" 2>/dev/null || true
cp "$SCRIPT_DIR/docs/ko-crash-course.md" "$DIST_DIR/docs/" 2>/dev/null || true
cp "$SCRIPT_DIR/docs/getting-started.md" "$DIST_DIR/docs/" 2>/dev/null || true

echo ""
echo "Built: $DIST_DIR/"
echo ""
echo "Contents:"
echo "  ko              - compiler binary"
echo "  ko-lsp          - language server"
echo "  std/            - standard library"
echo "  examples/       - example programs"
echo "  editors/        - VS Code extension + tree-sitter grammar"
echo "  docs/           - documentation"
echo ""
echo "Try it:"
echo "  echo 'fn main = println \"Hello, Kō!\"' > /tmp/hello.ko"
echo "  $DIST_DIR/ko /tmp/hello.ko"
echo ""
echo "Install anywhere:"
echo "  cp -r $DIST_DIR ~/ko"
echo "  ~/ko/ko some_program.ko"
