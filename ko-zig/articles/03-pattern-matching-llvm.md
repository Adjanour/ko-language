# Article 3: How Kō Compiles Pattern Matching to LLVM IR

## Target Audience
Compiler engineers, PL researchers, developers implementing pattern matching.

## Tone
Technical, precise, with working examples. This is a "how we did it" article.

## Word Count
4,000-5,000 words

## Structure

### Hook (200 words)
- Show a Kō pattern match:
  ```ko
  match expr
    | Cons x (Cons y rest) => x + y
    | Cons x Nil => x
    | Nil => 0
  ```
- Show the generated LLVM IR (simplified)
- Promise: by the end, you'll understand exactly how this compiles

### The Problem: What Is Pattern Matching? (400 words)
- Pattern matching is case analysis on structured data
- Sum types (ADTs) have constructors with tags
- Matching means: extract the tag, compare, bind variables, execute body
- The compiler must generate efficient code for this
- Naive approach: nested if-else trees. Better approach: flat comparison chains.

### Kō's Data Model (500 words)
- All values are `i64` at runtime
- Zero-argument constructors: value IS the tag (0, 1, 2, ...)
- Single-argument constructors: boxed struct `{ tag, value }` on heap
- Multi-argument constructors: boxed struct `{ tag, arg1, arg2, ... }` on heap
- Tuples: `{ val1, val2, ... }` on heap
- Records: `{ field1, field2, ... }` on heap
- The tag tells you what you have; the payload tells you what's inside

### The Compilation Strategy (600 words)

#### Step 1: Extract the Tag
- For zero-arg constructors: the value IS the tag
- For boxed values: load from heap pointer at offset 0
- The typechecker knows which case we're in (tag=100 for unknown)

#### Step 2: Create the Comparison Chain
- One basic block per match arm
- Each block: compare tag → branch to body or next comparison
- The chain is flat: no nesting, no if-else trees

#### Step 3: Bind Variables
- Destructure the payload in the body block
- GEP into the struct to extract fields
- Store in named_values for use in the body

#### Step 4: Merge Results
- Each body block branches to a common merge block
- Phi node in merge block combines all possible results
- The phi node knows all possible incoming values

### A Complete Example (800 words)

#### Input
```ko
type List a = Cons a (List a) | Nil

fn sum xs =
  match xs
    | Cons x (Cons y rest) => x + y + sum rest
    | Cons x Nil => x
    | Nil => 0
```

#### Step-by-Step Codegen

**1. Register constructor tags:**
```
Cons → tag 0
Nil → tag 1
```

**2. Create basic blocks:**
```
entry → cmp_cons_cons → cmp_cons_nil → cmp_nil → unreachable
cmp_cons_cons → body_cons_cons
cmp_cons_nil → body_cons_nil
cmp_nil → body_nil
body_cons_cons → merge
body_cons_nil → merge
body_nil → merge
merge → return
```

**3. Comparison chain:**
```llvm
; entry block
br label %cmp_cons_cons

; cmp_cons_cons: check if Cons
%tag = load i64, i64* %xs_ptr
%is_cons = icmp eq i64 %tag, 0
br i1 %is_cons, label %body_cons_cons, label %cmp_cons_nil

; cmp_cons_nil: check if Cons with Nil tail
; (nested pattern: destructure tail, check its tag)
...

; cmp_nil: check if Nil
%is_nil = icmp eq i64 %tag, 1
br i1 %is_nil, label %body_nil, label %unreachable
```

**4. Variable binding in body:**
```llvm
; body_cons_cons: bind x, y, rest
%x_ptr = getelementptr { i64, i64 }, { i64, i64 }* %xs_ptr, i32 0, i32 1
%x = load i64, i64* %x_ptr
; destructure tail...
```

**5. Merge with phi:**
```llvm
; merge block
%result = phi i64 [ %body_val_1, %body_cons_cons ], [ %body_val_2, %body_cons_nil ], [ %body_val_3, %body_nil ]
ret i64 %result
```

### Nested Patterns (600 words)
- `Cons x (Cons y rest)` is a nested pattern
- We destructure during comparison: extract tail, check its tag
- This is "inlined" destructuring — no extra basic blocks for the nesting
- The typechecker knows the structure, so we can GEP directly

### Wildcard Patterns (300 words)
- `_` matches anything, binds nothing
- No variable extraction needed
- Just compare and branch

### Literal Patterns (300 words)
- `| 42 => ...` matches a specific integer
- Compare value directly: `icmp eq i64 %val, 42`
- Same as constructor matching, but comparing payloads

### Record Patterns (400 words)
- `| { name, age } => ...` destructures a record
- GEP to extract fields by index
- `..` (rest) means "ignore remaining fields"
- No tag comparison needed — records have no tag (they're structs)

### The Gotchas (500 words)

#### Unreachable Blocks
- Create the unreachable block BEFORE the entry branch
- If you create it after, the first br gets built in the wrong block

#### Phi Node Incoming Values
- `LLVMAddIncoming` takes `LLVMBasicBlockRef`, not `LLVMIBasicBlockRef`
- The block must have already been created and have a terminator

#### Type Tags for Unknown Types
- When the typechecker can't determine the type (imported values), tag is 100
- `println xs` where xs is a list prints with tag 100
- Workaround: bind to a variable first

#### Exhaustiveness
- Kō doesn't check exhaustiveness at compile time (yet)
- Missing patterns hit the unreachable block at runtime
- Future: compile-time exhaustiveness checking

### Performance (300 words)
- Comparison chains are O(n) in the number of arms
- LLVM optimizes this into jump tables when possible
- No heap allocation for pattern matching itself
- The tag comparison is a single integer comparison

### Comparison to Other Languages (400 words)

#### OCaml
- Similar compilation strategy
- OCaml uses jump tables for dense tags
- Kō uses comparison chains (simpler, works for sparse tags)

#### Haskell
- Lazy evaluation changes the strategy
- Kō's eager evaluation makes pattern matching simpler
- No thunks to force

#### Rust
- Exhaustiveness checking at compile time
- Kō could add this (future work)

#### Haskell's ViewPatterns
- Kō doesn't have view patterns (yet)
- Would require function application during matching

### Conclusion (200 words)
- Pattern matching is the heart of Kō's control flow
- The compilation strategy is straightforward: extract tag, compare, bind, merge
- LLVM handles the optimization
- The hard parts: nested patterns, unreachable blocks, phi nodes
- The result: efficient native code with no runtime overhead

---

## Key Code Snippets to Include

1. The Kō source pattern match
2. The AST representation of patterns
3. The codegen for comparison chains
4. The codegen for variable binding
5. The phi node construction
6. The unreachable block handling

## Images/Diagrams
1. Control flow graph for a match expression
2. Memory layout of sum types (tagged union)
3. The comparison chain (entry → cmp[0] → cmp[1] → ...)
4. Phi node merging
5. Nested pattern destructuring

## Publishing Platforms
- Personal blog
- LLVM Dev Meeting (if timing works)
- Reddit (r/Compilers, r/ProgrammingLanguages)
- Hacker News
- ACM Queue / Communications of the ACM (if polished enough)
