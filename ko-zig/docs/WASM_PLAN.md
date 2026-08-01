# Kō → WebAssembly Compilation Plan

## Goal

Compile Kō programs to WebAssembly for browser and Node.js deployment.

## Architecture Overview

### Current Pipeline
```
Source → Lexer → Parser → AST → Typechecker → HIR → LIR → LLVM IR → Machine code
```

### Proposed WASM Pipeline
```
Source → Lexer → Parser → AST → Typechecker → HIR → LIR → WASM binary
```

The LIR layer (`src/lir.zig`) is already machine-oriented with basic blocks, explicit memory ops, reference counting, and closure conversion — it maps naturally to WASM.

---

## Phase 1: LLVM WASM Backend (Quick Prototype)

**Duration:** 1-2 weeks
**Goal:** Get Kō programs compiling to WASM via LLVM's existing WASM backend

### What Changes

#### 1.1 Target Triple Configuration
File: `src/codegen.zig` and `src/codegen_lir.zig`

```zig
// Add WASM target option
const wasm_target = "wasm32-unknown-unknown";
const wasm_data_layout = "e-m:e-p:32:32-i64:64-n32:64-S128";

// In init():
if (use_wasm) {
    core.LLVMSetTarget(mod, wasm_target);
    core.LLVMSetDataLayout(mod, wasm_data_layout);
}
```

#### 1.2 Runtime Replacement
WASM has no OS. The runtime functions in `src/stdlib.zig` need WASM-compatible versions:

| Function | WASM Implementation |
|----------|---------------------|
| `ko_alloc(size)` | Bump allocator in linear memory + `memory.grow` |
| `ko_incref(ptr)` | Same logic, i32 pointer arithmetic |
| `ko_decref(ptr)` | Same logic, free list or bump reset |
| `ko_int_to_string` | Pure WASM implementation (no libc) |
| `ko_init_stack()` | WASM stack pointer from `__stack_pointer` global |
| `ko_check_stack()` | Compare against stack limit global |

#### 1.3 I/O Imports
WASM cannot do I/O directly. Create JS imports:

```javascript
// glue.js
const imports = {
    env: {
        println_i64: (val) => console.log(val),
        println_string: (ptr, len) => {
            const bytes = new Uint8Array(memory.buffer, ptr, len);
            console.log(new TextDecoder().decode(bytes));
        },
        print_string: (ptr, len) => { /* ... */ },
        inspect: (val, tag) => { /* ... */ },
        panic: (msg_ptr, msg_len) => { /* throw error */ },
    }
};
```

#### 1.4 64-bit to 32-bit Adaptation
WASM32 uses i32 for pointers. Options:

- **Option A:** Use i64 everywhere (WASM supports i64 natively, slightly larger code)
- **Option B:** Use i32 for pointers, i64 for values (complex mapping)
- **Recommendation:** Use i64 everywhere for simplicity, target WASM32 with i64 support

#### 1.5 String Handling
Strings are byte arrays in linear memory. Need:
- Null-terminated strings in memory
- String operations as WASM imports or pure WASM implementations

### Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `src/stdlib_wasm.zig` | Create | WASM-compatible runtime (alloc, RC, I/O stubs) |
| `src/codegen.zig` | Modify | Add WASM target triple option |
| `src/main.zig` | Modify | Add `--emit-wasm` CLI flag |
| `glue.js` | Create | JavaScript glue for WASM instantiation |
| `build.zig` | Modify | Add WASM build step |

### Build Commands

```bash
# Compile Kō to WASM via LLVM
ko --emit-wasm output.wasm program.ko

# Or via build step
zig build -Dtarget=wasm32-unknown-unknown
```

### Limitations

- LLVM WASM backend produces bloated code
- Requires `wasm-ld` linker
- No browser optimization (tree-shaking, minification)
- Good for proof of concept, not production

---

## Phase 2: Direct LIR → WASM Codegen (Production Quality)

**Duration:** 2-3 months
**Goal:** Write a dedicated WASM codegen backend that maps LIR directly to WASM binary

### Architecture

```
LIR (BasicBlocks, LirStmt, LirValue, LirTerminator)
    ↓
WasmModule (functions, memories, imports, exports)
    ↓
WasmBinary (binary encoding)
```

### 2.1 WASM Module Structure

```zig
// src/wasm.zig — WASM binary format types

pub const WasmModule = struct {
    types: []const FuncType,
    functions: []const Function,
    memories: []const Memory,
    globals: []const Global,
    imports: []const Import,
    exports: []const Export,
    data_segments: []const DataSegment,
};

pub const FuncType = struct {
    params: []const ValType,
    results: []const ValType,
};

pub const ValType = enum(u8) {
    i32 = 0x7F,
    i64 = 0x7E,
    f32 = 0x7D,
    f64 = 0x7C,
};
```

### 2.2 LIR → WASM Mapping

| LIR Construct | WASM Equivalent |
|---------------|-----------------|
| `BasicBlock` | WASM `block`/`loop` |
| `LirTerminator.br` | `br` (label index) |
| `LirTerminator.cond_br` | `if` + `br_if` |
| `LirTerminator.switch_` | `br_table` |
| `LirTerminator.ret` | `return` |
| `LirStmt.assign` | `local.set` |
| `LirValue.local` | `local.get` |
| `LirValue.int` | `i64.const` |
| `LirValue.call` | `call` |
| `LirValue.alloc` | `call $ko_alloc` (import) |
| `LirValue.load` | `i64.load` |
| `LirValue.incref` | `call $ko_incref` |
| `LirValue.decref` | `call $ko_decref` |
| Binary ops (`add`, `sub`, etc.) | `i64.add`, `i64.sub`, etc. |
| Comparisons (`eq`, `lt`, etc.) | `i64.eq`, `i64.lt_s`, etc. |

### 2.3 Control Flow Compilation

WASM uses structured control flow. The LIR's basic blocks need nesting:

```
LIR:
  bb0: ...
      br bb1
  bb1: ...
      cond_br cond, bb2, bb3
  bb2: ...
      br bb4
  bb3: ...
      br bb4
  bb4: return result

WASM:
  block $bb4
    block $bb3
      block $bb2
        block $bb1
          ;; bb0 code
          br $bb1
        end ;; bb1
        ;; bb1 code
        br_if $bb3  ;; if false, go to bb3
        ;; bb2 code
        br $bb4
      end ;; bb2
      ;; bb3 code
      br $bb4
    end ;; bb3
  end ;; bb4
  ;; bb4 code
  return
```

For loops (`LirTerminator.br` back to earlier block):
```
loop $loop
  ;; loop body
  br_if $loop  ;; continue
  br $exit     ;; break
end
```

### 2.4 Memory Model

WASM linear memory:
```
+------------------+------------------+------------------+
| Stack (grows ↓)  | Heap (grows ↑)   | Data (static)    |
+------------------+------------------+------------------+
0x0000             stack_top          memory_end         0xFFFF (initial)
```

Runtime functions in WASM:
```wat
(memory 1 100)  ;; initial 1 page (64KB), max 100 pages

(global $heap_ptr (mut i32) (i32.const 65536))  ;; starts after data

(func $ko_alloc (param $size i32) (result i32)
  (local $ptr i32)
  (local.set $ptr (global.get $heap_ptr))
  (global.set $heap_ptr
    (i32.add (global.get $heap_ptr) (local.get $size))
  )
  ;; TODO: bump memory.grow if needed
  (local.get $ptr)
)
```

### 2.5 Reference Counting in WASM

```wat
(func $ko_incref (param $ptr i32) (result i32)
  (i64.store
    (i32.sub (local.get $ptr) (i32.const 8))
    (i64.add
      (i64.load (i32.sub (local.get $ptr) (i32.const 8)))
      (i64.const 1)
    )
  )
  (local.get $ptr)
)

(func $ko_decref (param $ptr i32)
  (local $rc i64)
  (local.set $rc
    (i64.load (i32.sub (local.get $ptr) (i32.const 8)))
  )
  (if (i64.le_s (local.get $rc) (i64.const 0))
    (then
      ;; free: no-op in bump allocator, or add to free list
    )
    (else
      (i64.store
        (i32.sub (local.get $ptr) (i32.const 8))
        (i64.sub (local.get $rc) (i64.const 1))
      )
    )
  )
)
```

### 2.6 String Operations

Strings as byte arrays in linear memory:
```wat
;; String.length: read length prefix
(func $ko_string_length (param $ptr i32) (result i64)
  (i64.load (i32.sub (local.get $ptr) (i32.const 8)))  ;; length prefix
)

;; String.append: allocate new buffer, copy
(func $ko_string_append (param $a_ptr i32) (param $b_ptr i32) (result i32)
  (local $a_len i64)
  (local $b_len i64)
  (local $new_len i64)
  (local $new_ptr i32)
  ;; ... implementation
)
```

### 2.7 JS Glue Code

```javascript
// ko-runtime.js
class KoRuntime {
  constructor(wasmModule) {
    this.memory = new WebAssembly.Memory({ initial: 256, maximum: 1024 });
    this.instance = null;
  }

  async instantiate(wasmBytes) {
    const importObject = {
      env: {
        memory: this.memory,
        println_i64: (val) => console.log(val),
        println_string: (ptr) => {
          const len = this.readI64(ptr - 8);
          const bytes = new Uint8Array(this.memory.buffer, ptr, Number(len));
          console.log(new TextDecoder().decode(bytes));
        },
        panic: (ptr) => {
          const len = this.readI64(ptr - 8);
          const bytes = new Uint8Array(this.memory.buffer, ptr, Number(len));
          throw new Error(new TextDecoder().decode(bytes));
        },
        // ... more imports
      }
    };
    this.instance = await WebAssembly.instantiate(wasmBytes, importObject);
  }

  run() {
    return this.instance.exports.main();
  }
}
```

### Files to Create

| File | Description |
|------|-------------|
| `src/wasm.zig` | WASM binary format types and encoder |
| `src/codegen_wasm.zig` | LIR → WASM code generator |
| `src/stdlib_wasm.zig` | WASM runtime (alloc, RC, strings) |
| `glue/ko-browser.js` | Browser runtime |
| `glue/ko-node.js` | Node.js runtime |
| `glue/ko-loader.js` | WASM module loader |

### Build Commands

```bash
# Compile Kō to WASM (direct codegen)
ko --emit-wasm output.wasm program.ko

# With optimization
ko --emit-wasm --optimize output.wasm program.ko

# Compile to WASM + JS glue
ko --emit-wasm-app output_dir/ program.ko
```

---

## Phase 3: Runtime and Ecosystem

**Duration:** 1-2 months
**Goal:** Complete WASM runtime, tooling, and browser integration

### 3.1 Browser API Bindings

```ko
import browser.{document, window, fetch}

fn main =
  let el = document.getElementById "app"
  el.innerHTML = "<h1>Hello from Kō!</h1>"
  
  fetch "/api/data"
    |> then (\response -> response.json ())
    |> then (\data -> println data)
```

Requires:
- DOM API bindings (generated from Web IDL)
- Fetch API bindings
- Event loop integration

### 3.2 Node.js Integration

```bash
# Run Kō program in Node.js
ko --run-wasm program.ko

# Or use the compiled WASM directly
node -e "require('./glue/ko-node.js').run('./output.wasm')"
```

### 3.3 Package Distribution

```bash
# Build for npm
ko build --target wasm --out dist/ program.ko

# Generates:
# dist/program.wasm
# dist/program.js (loader)
# dist/program.d.ts (TypeScript types)
```

### 3.4 Testing Strategy

- Unit tests: WASM binary encoding correctness
- Integration tests: compile Kō → WASM → run in Node.js → check output
- Browser tests: compile Kō → WASM → load in browser → verify behavior
- Benchmark: compare WASM performance vs native LLVM

---

## Technical Challenges and Solutions

### Challenge 1: 64-bit Values in WASM32

**Problem:** Kō uses i64 for all values. WASM32 has 32-bit pointers.

**Solution:** Use i64 everywhere. WASM supports i64 natively:
- Pointers stored as i64 (zero-extended from i32 when loading from memory)
- All Kō values remain i64
- Slightly larger code, but simpler implementation

### Challenge 2: Structured Control Flow

**Problem:** WASM requires structured control flow; LIR has arbitrary CFG.

**Solution:** Use the block/loop/if nesting pattern:
- Forward branches → `block` + `br`
- Backward branches (loops) → `loop` + `br_if`
- Conditional → `if`/`else`
- The HIR→LIR pass already handles this pattern for pattern matching

### Challenge 3: Tail Calls

**Problem:** WASM doesn't guarantee tail call optimization.

**Solution:**
- Use `tail_call` Wasm extension (when available)
- Or convert tail calls to loops at LIR level
- The existing TCO detection in `codegenFn` can be extended

### Challenge 4: Closures in WASM

**Problem:** WASM functions can't capture variables from enclosing scope.

**Solution:** Closure conversion (already in LIR lowering):
- Closures become heap-allocated structs: `{ fn_ptr, cap0, cap1, ... }`
- The closure's wrapper function loads captures from the struct
- This is already how Kō handles closures in LLVM codegen

### Challenge 5: Exception Handling

**Problem:** WASM has no native exceptions (yet).

**Solution:**
- Use `panic` as imported function that throws JS exception
- Or use WASM exception handling proposal (when available)
- For now, `panic` calls `unreachable` + JS catch

---

## Implementation Order

### Phase 1 (Weeks 1-2): Quick Prototype
1. Add WASM target triple to LLVM codegen
2. Implement minimal `ko_alloc` in WASM
3. Create JS glue for I/O
4. Test with simple programs (fibonacci, factorial)
5. Document limitations

### Phase 2 (Months 1-3): Production WASM Backend
1. Design WASM binary format types (`wasm.zig`)
2. Implement WASM binary encoder
3. Create LIR → WASM codegen (`codegen_wasm.zig`)
4. Implement WASM runtime (`stdlib_wasm.zig`)
5. Handle control flow (blocks, loops, conditionals)
6. Handle closures and partial application
7. Handle pattern matching (switch/br_table)
8. Create JS runtime for browser and Node.js
9. Test with full Kō test suite
10. Benchmark against native

### Phase 3 (Months 4-5): Ecosystem
1. Browser API bindings (DOM, fetch, events)
2. Node.js integration
3. Package distribution
4. Documentation and tutorials
5. VS Code WASM debugging support

---

## Success Criteria

### Phase 1
- [ ] `ko --emit-wasm hello.wasm hello.ko` produces valid WASM
- [ ] `node run.js hello.wasm` prints "Hello, World!"
- [ ] Basic arithmetic and string operations work

### Phase 2
- [ ] All 155+ Kō tests pass in WASM
- [ ] Pattern matching works correctly
- [ ] Closures and partial application work
- [ ] Reference counting prevents memory leaks
- [ ] Performance within 2x of native (for compute-bound code)

### Phase 3
- [ ] Browser demo (interactive calculator, game, etc.)
- [ ] Node.js package on npm
- [ ] Documentation with examples

---

## References

- [WebAssembly Specification](https://webassembly.org/spec/)
- [WASM Binary Format](https://webassembly.org/spec/binary/)
- [WABT (WebAssembly Binary Toolkit)](https://github.com/WebAssembly/wabt)
- [wasm-tools (Rust)](https://github.com/bytecodealliance/wasm-tools)
- [LLVM WASM Backend](https://llvm.org/docs/WebAssembly.html)
- [WASM Tail Call Proposal](https://github.com/WebAssembly/tail-call)
- [WASM Exception Handling](https://github.com/WebAssembly/exception-handling)
