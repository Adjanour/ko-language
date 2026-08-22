---
title: "Install Kō"
---

# Install Kō

Get Kō running on your machine in a few minutes.

---

## Prerequisites

Kō needs two things:

- **Zig 0.17** — the compiler that builds Kō
- **LLVM 22** — the backend that generates native code

### Install Zig

Download from [ziglang.org](https://ziglang.org/download/). Extract and add to PATH.

### Install LLVM

**Ubuntu / Debian:**

```bash
sudo apt install llvm-22-dev zlib1g-dev
```

**Arch:**

```bash
sudo pacman -S llvm zlib
```

**macOS:**

```bash
brew install llvm@22
export PATH="/opt/homebrew/opt/llvm@22/bin:$PATH"
```

---

## Build from Source

Clone the repo and build:

```bash
git clone https://github.com/Adjanour/ko-language.git
cd ko-language/ko-zig
zig build
```

The `ko` binary is at `zig-out/bin/ko`.

### Or use the build script

```bash
git clone https://github.com/Adjanour/ko-language.git
cd ko-language
./build.sh
```

This builds the compiler and puts the binary in `ko-dist/`.

---

## Verify It Works

Create a file called `hello.ko`:

```ko
fn main =
    println "Hello, Kō!"
```

Run it:

```bash
./zig-out/bin/ko hello.ko
```

You should see:

```
Hello, Kō!
```

---

## Editor Setup

Kō ships with a VS Code extension and tree-sitter grammar.

### VS Code

Install the extension from the repo:

```bash
code --install-extension vscode-ko/ko-language-0.5.0.vsix
```

### Other editors

Tree-sitter grammar is in `tree-sitter-ko/`. Any editor with tree-sitter support can use it.

See [Editor Setup](editor-setup) for details.

---

## What's Next?

- [Tutorial](tutorial) — learn Kō from scratch
- [Writing Kō Programs](writing-ko-programs) — patterns and constraints
- [Language Reference](reference) — complete syntax reference
