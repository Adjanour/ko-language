# Cross-Platform Strategy

Status: Implementation in Progress
Date: 2026-08-18

## The Thesis

Kō compiles to LLVM IR, and LLVM supports every major platform. Zig's build system provides cross-compilation for free via `-target`. The combination means Kō can produce native binaries for Linux, macOS, and Windows from any build host — with minimal platform-specific code.

## Two Separate Problems

**Problem A: The compiler itself.** The Kō compiler (lexer, parser, typechecker, codegen, LSP, REPL) must run on the developer's machine. Zig's stdlib handles this — just replace raw Linux syscalls with `std.posix`.

**Problem B: Generated Kō binaries.** When a user runs `ko --emit-exe program.ko`, the output binary must run on the target platform. This requires a portable runtime and cross-linking.

## Current Platform Coupling

| Layer | Files | Issue |
|-------|-------|-------|
| Compiler I/O | `codegen.zig`, `stdlib.zig`, `lsp.zig`, `repl.zig`, `module_loader.zig` | Raw `linux.write`/`linux.close` — **DONE (Phase 0)**, replaced with `std.c.*` |
| Generated code runtime | `stdlib_codegen.zig` | Kō binaries call libc: `malloc`, `free`, `printf`, `abort`, ctype functions — `ko_panic` ported to `write(2)` |
| Linker dispatch | `main.zig` | Hardcoded linker args per OS — **DONE (Phase 1)**, replaced with `zig cc` |
| REPL | `repl.zig`, `linenoise.zig` | POSIX signals, `setjmp`/`longjmp`, linenoise C lib |
| Architecture | `codegen.zig:4148` | Stack direction assumed x86-64 |

## What Zig Gives Us for Free

1. **`std.posix`** — cross-platform POSIX API. `std.posix.read()`, `std.posix.write()`, `std.posix.openat()` work on Linux, macOS, FreeBSD, and Windows (via WinRT POSIX layer).
2. **`std.process.Child`** — cross-platform process spawning.
3. **`-target` flag** — `build.zig` already uses `b.standardTargetOptions()`. Users pass `-target aarch64-macos` and get the right binary.
4. **Cross-linking** — Zig ships with CRT objects, musl, and mingw. `zig cc -target x86_64-windows` links Windows binaries from Linux.
5. **`comptime` OS dispatch** — compile-time platform switches with zero overhead.

## The Zig Cross-Linker Approach

Zig can act as a cross-linker for any Tier 1 target:

```bash
# From Linux, produce a macOS binary:
ko --emit-obj -target aarch64-macos program.ko
zig cc -target aarch64-macos program.o -o program -lc -lm

# From Linux, produce a Windows binary:
ko --emit-obj -target x86_64-windows-gnu program.ko
zig cc -target x86_64-windows-gnu program.o -o program.exe -lc -lm
```

This works because:
- LLVM emits object files for the target triple (ELF, Mach-O, COFF)
- Zig provides the right CRT, libc, and linker flags for every target
- No need to maintain platform-specific linker paths in `main.zig`

## Phased Implementation

### Phase 0: Compiler I/O Cleanup

Replace all raw `linux.write`/`linux.close` with `std.posix` equivalents. This makes the compiler compile on all platforms.

| File | Line | Change |
|------|------|--------|
| `codegen.zig` | 3764 | `sout()` — `std.posix.write(.stdout, ...)` |
| `codegen.zig` | 4172 | Stack overflow — `std.posix.write(.stderr, ...)` |
| `stdlib.zig` | 331 | `ko_panic` — `std.posix.write(.stderr, ...)` |
| `lsp.zig` | 228 | `writeAll` — remove linux-specific branch, use `std.posix.write` |
| `repl.zig` | 44, 63 | Signal handler + `writeAll` — `std.posix.write` |
| `module_loader.zig` | 230 | `closeFd` — `std.posix.close()` |

Also add Windows cases to `comptime` OS switches where `std.posix` isn't sufficient.

### Phase 1: Linker Abstraction — DONE

Replace the hardcoded linker dispatch in `main.zig` with `zig cc`:

```zig
// New: use zig cc as cross-linker
const ld_argv: []const []const u8 = if (target_triple) |triple|
    &.{ "zig", "cc", "-target", triple, obj_name, "-o", out_name_z, "-lc", "-lm" }
else
    &.{ "zig", "cc", obj_name, "-o", out_name_z, "-lc", "-lm" };
```

This eliminates 30+ lines of hardcoded paths and enables cross-compilation of Kō output.

Notes from implementation:

- **Object emission lives in `codegen_lir.zig`** (`emitObjectFile`), not the frozen `codegen.zig` Aot. It reads the module triple, initializes all LLVM targets (`LLVMInitializeAll*`), and emits via a target machine.
- **Triple normalization:** LLVM's short triple parser does not resolve the OS for 2-part triples like `aarch64-macos` (produces ELF instead of Mach-O). `emitObjectFile` normalizes with `LLVMNormalizeTargetTriple` before creating the target machine. `zig cc -target` receives the original Zig-form triple (Zig parses it correctly).
- **Environment fix:** `main.zig` initialized `Io.Threaded` with the default *empty* environment, so child processes got no `PATH` and `zig cc` couldn't be found. Now passes `init.minimal.environ`.
- **`--target` flag:** added to CLI, parsed into `target_triple`, passed to `CodegenLir.setTargetTriple` (new method on the module) and to `zig cc`.
- **Cross-compilation verified:** `--emit-exe --target` works for `aarch64-macos` (Mach-O), `x86_64-windows-gnu` (PE), `aarch64-linux-gnu` (ELF), and native x86_64-linux.

### Phase 2: REPL Signal Handling

Replace POSIX `sigaction`/`longjmp` with platform-specific handlers:
- **Linux/macOS:** `std.posix.sigaction` (already works)
- **Windows:** `std.os.windows.SetConsoleCtrlHandler`
- **Fallback:** Minimal stdin loop on unsupported platforms

**Progress (in progress):**
- Added `src/linenoise_win.zig` — a Windows fallback for linenoise with the same API surface (fd-based line reading via `fdio`, in-memory history with file save/load, no raw mode). Verified to compile for `x86_64-windows-gnu`.
- `src/repl.zig` now selects the backend per platform (`if (is_windows) @import("linenoise_win.zig") else @import("linenoise")`); `sigaction`/`sigHandler`/`setjmp` are all guarded by `comptime !is_windows`. Windows Ctrl+C uses default CRT termination for now — `SetConsoleCtrlHandler` is the remaining Phase 2 item.
- Added `src/fdio.zig` — portable integer-fd I/O shim (`fd_t = c_int`, `stdin/stdout/stderr` = 0/1/2). Dispatch: POSIX → `std.c.write/read/close/open`; Windows → CRT `_write/_read/_close/_open`. Required because `std.c.fd_t` is `*anyopaque` (HANDLE) on Windows, so `std.c.write(2, ...)` does not compile there.
- Converted `src/lsp.zig`, `src/repl.zig`, `src/stdlib.zig`, `src/module_loader.zig` to `fdio`.

**Remaining (blocked on LLVM system libs):**
- Full `ko` exe cross-build to Windows/macOS is blocked in this environment by `LLVM-22`/`z` system libraries having no cross versions (`zig build -Dtarget=x86_64-windows-gnu` fails at library lookup before compiling sources). `ko-lsp` has no LLVM dependency and IS verifiable: it now cross-compiles to Linux ELF, macOS Mach-O arm64, and Windows PE32+ console, and responds correctly to LSP messages over pipes on Linux.
- Frozen `codegen.zig` still contains `std.c.write(1/2, ...)` calls (legacy AOT `sout`/stack-trace paths) that would break a Windows compile of the full compiler. Left untouched per the freeze rule; the ko exe Windows build is blocked on LLVM anyway.

### Phase 3: Generated Code Runtime

Make the Kō runtime portable for generated binaries:
- Keep libc for now (provided by `zig cc` for all targets)
- Replace `printf`/`fprintf` with platform-abstracted `ko_write` in generated code — **partial**: `ko_panic` now emits raw `write(2, ...)` instead of `fprintf(stderr, ...)`, removing the glibc-specific `stderr` symbol dependency (this was the remaining blocker for macOS/Windows links). `println` still uses libc stdio.
- Replace `sin`/`cos`/`sqrt` with LLVM intrinsics
- Eventually: custom `_start` to eliminate CRT (per DESIGN-runtime-independence.md)

### Phase 4: Build System

Update `build.zig`:
- Add `cross-link` step using `zig cc`
- Pass target triple through to LLVM for object file emission
- Add CI jobs for cross-compilation testing

## Target Matrix

| Target | Compiler | Generated binaries | Priority |
|--------|----------|-------------------|----------|
| x86_64-linux | Tier 1 | Tier 1 | Current |
| aarch64-macos | Tier 1 | **Done** | High |
| x86_64-macos | Tier 1 | **Done** | High |
| aarch64-linux | Tier 1 | **Done** | Medium |
| x86_64-windows | **ko-lsp done** | **Done** | Medium |
| aarch64-windows | Phase 3 | Phase 3 | Low |

Cross-compilation of `--emit-exe` output is implemented and verified for the four targets above (Mach-O / PE / ELF / ELF). Executables are produced but have not yet been *run* on the target platforms. The compiler itself (ko-lsp, no LLVM dependency) cross-compiles to Linux, macOS arm64, and Windows x86_64.

## Success Criteria

- `zig build` produces a working compiler on Linux, macOS, and Windows
- `ko --emit-exe -target aarch64-macos src.ko` produces a working macOS binary from Linux — **binary produced; runtime execution on macOS not yet verified**
- `ko --emit-exe -target x86_64-windows-gnu src.ko` produces a working Windows binary from Linux — **binary produced; runtime execution on Windows not yet verified**
- No raw `linux.*` syscalls remain in the compiler (only in generated runtime code)
- REPL works on Linux and macOS — **Linux verified; Windows REPL uses linenoise_win fallback (compiles, untested at runtime)**
