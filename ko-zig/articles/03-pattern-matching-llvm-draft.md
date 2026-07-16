# How Kō Compiles Pattern Matching to Native Code

Pattern matching is the heart of Kō. There's no while loop, no for loop, no switch statement. Just match. If you want to do different things for different shapes of data, you match on the shape. If you want to repeat something, you use recursion. If you want to transform a list, you use map or filter. Pattern matching is the only control flow you need.

This sounds limiting until you realize how much you can do with it. Sorting a list? Match on whether it's empty, a single element, or two elements with a rest. Parsing a string? Match on the first character and recurse. Implementing an interpreter? Match on the expression type and evaluate each case. Pattern matching is surprisingly powerful once you stop reaching for loops.

But there's a problem. Pattern matching is elegant in source code. How do you compile it to machine code?

---

Consider this Kō code:

```ko
type List a = Cons a (List a) | Nil

fn sum xs =
  match xs
    | Cons x rest => x + sum rest
    | Nil => 0
```

The programmer writes a match expression. The compiler must turn this into LLVM IR that runs on actual hardware. What does that look like?

The naive approach is nested if-else trees. Check if xs is Cons, then check if the tail is Cons, then check if it's Nil. But this doesn't scale. If you have ten match arms, you get ten levels of nesting. The code becomes unreadable, and the compiler has no way to optimize.

The better approach is a comparison chain. One basic block per match arm. Each block compares the tag and branches to the body or the next comparison. A phi node merges results at the end.

It's flat. It's efficient. It's what every serious compiler does.

---

Let's trace through the compilation of `sum`.

First, the compiler registers the constructor tags. Cons gets tag 0. Nil gets tag 1. These are sequential integers starting from zero. The typechecker knows which constructors belong to which type, and it passes this information to the codegen.

Next, the compiler creates basic blocks. One entry block, two comparison blocks, two body blocks, one merge block, one unreachable block. The comparison blocks check the tag. The body blocks bind variables and evaluate the arm. The merge block combines results. The unreachable block handles the case where no arm matches (which shouldn't happen for exhaustive patterns, but the compiler generates it anyway for safety).

Then the compiler builds the comparison chain. The entry block branches to the first comparison block. The first comparison block checks if the tag is 0 (Cons). If yes, it branches to the first body block. If no, it branches to the second comparison block. The second comparison block checks if the tag is 1 (Nil). If yes, it branches to the second body block. If no, it branches to the unreachable block.

The body blocks bind variables. The first body block extracts x and rest from the Cons payload. The second body block doesn't need to extract anything — Nil has no payload. Then each body block evaluates its arm and branches to the merge block.

The merge block uses a phi node to combine results. If the first arm matched, the result is `x + sum rest`. If the second arm matched, the result is 0. The phi node selects the right value based on which body block was executed.

Finally, the merge block returns the result.

---

The LLVM IR looks something like this:

```llvm
; Entry block
br label %cmp_cons

; Check if Cons
cmp_cons:
  %tag = load i64, i64* %xs_ptr
  %is_cons = icmp eq i64 %tag, 0
  br i1 %is_cons, label %body_cons, label %cmp_nil

; Check if Nil
cmp_nil:
  %is_nil = icmp eq i64 %tag, 1
  br i1 %is_nil, label %body_nil, label %unreachable

; Bind x and rest, evaluate arm
body_cons:
  %x_ptr = getelementptr { i64, i64 }, { i64, i64 }* %xs_ptr, i32 0, i32 1
  %x = load i64, i64* %x_ptr
  %rest_ptr = getelementptr { i64, i64 }, { i64, i64 }* %xs_ptr, i32 0, i32 2
  %rest = load i64, i64* %rest_ptr
  %sum_rest = call i64 @sum(i64 %rest)
  %result_cons = add i64 %x, %sum_rest
  br label %merge

; Evaluate arm
body_nil:
  br label %merge

; Combine results
merge:
  %result = phi i64 [ %result_cons, %body_cons ], [ 0, %body_nil ]
  ret i64 %result

; No match (shouldn't happen)
unreachable:
  call void @llvm.trap()
  unreachable
```

It's straightforward. One comparison per arm. One branch per comparison. One phi to merge. No nesting, no complexity. Just a flat chain of comparisons and branches.

---

Nested patterns are where it gets interesting. Consider:

```ko
fn sum2 xs =
  match xs
    | Cons x (Cons y rest) => x + y + sum2 rest
    | Cons x Nil => x
    | Nil => 0
```

The first arm has a nested pattern: `Cons x (Cons y rest)`. The outer Cons matches the top-level structure. The inner Cons matches the tail. This is a nested pattern.

The compiler handles this by inlining the destructuring during comparison. When checking the first arm, it first checks if the tag is Cons. If yes, it extracts the tail. Then it checks if the tail's tag is Cons. If yes, it extracts y and rest. If the tail's tag is Nil, it falls through to the next comparison.

The comparison chain becomes:

```
entry → cmp_cons → (is Cons? → destructure tail → cmp_tail_cons → ...)
       cmp_cons → (not Cons → cmp_nil → ...)
       cmp_tail_cons → (is Cons? → body_cons_cons → ...)
       cmp_tail_cons → (not Cons → body_cons_nil → ...)
```

The key insight is that we destructure during comparison. We don't create separate basic blocks for each level of nesting. We just extract fields and continue comparing. This keeps the control flow flat and the code efficient.

---

Wildcard patterns are simple. `_` matches anything, binds nothing. The compiler doesn't need to extract any variables. It just compares and branches. The body block has no variable bindings — it just evaluates the arm.

Literal patterns are simple too. `| 42 => ...` matches a specific integer. The compiler compares the value directly: `icmp eq i64 %val, 42`. Same as constructor matching, but comparing payloads instead of tags.

Record patterns are interesting. `| { name, age } => ...` destructures a record. The compiler uses GEP to extract fields by index. The `..` syntax means "ignore remaining fields." No tag comparison needed — records don't have tags. They're just structs.

---

The tricky parts are the ones that can trip you up.

Unreachable blocks. If you create the unreachable block after the comparison chain, the first branch gets built in the wrong block. You need to create it before the entry branch. This is a subtle LLVM ordering issue that took me hours to debug.

Phi node incoming values. `LLVMAddIncoming` takes `LLVMBasicBlockRef`, not `LLVMIBasicBlockRef`. The types are different in the LLVM bindings. If you use the wrong one, you get a segfault.

Type tags for unknown types. When the typechecker can't determine the type (imported values, for example), the tag is 100. `println xs` where xs is a list prints with tag 100. The workaround is to bind to a variable first, which lets the typechecker infer the type.

Exhaustiveness. Kō doesn't check exhaustiveness at compile time. Missing patterns hit the unreachable block at runtime. This is a limitation, but it's also simpler. Exhaustiveness checking is a hard problem, and for now, Kō doesn't solve it. Future work.

---

Pattern matching compiles to efficient code. The comparison chain is O(n) in the number of arms. LLVM optimizes this into jump tables when possible. There's no heap allocation for pattern matching itself. The tag comparison is a single integer comparison. The variable binding is just a few GEP and load instructions.

For most programs, pattern matching is fast enough that you don't need to think about it. The compiler generates good code, and LLVM optimizes it further. The only time you need to worry is when you have hundreds of match arms — then the comparison chain becomes a linear scan, and a jump table would be faster. But for typical programs, this isn't an issue.

---

Other languages compile pattern matching differently.

OCaml uses a similar comparison chain strategy. It also uses jump tables for dense tags. Kō could do this too, but for now, it sticks with comparison chains. They're simpler and work for sparse tags.

Haskell's lazy evaluation changes the strategy. With laziness, you might not evaluate the scrutinee until you need it. Kō's eager evaluation makes pattern matching simpler — you always evaluate the scrutinee, and you always compare the tag.

Rust adds exhaustiveness checking. The compiler verifies that all cases are covered. Kō could add this, and it probably should. But it's not there yet.

Haskell's view patterns let you apply functions during matching. Kō doesn't have view patterns. It could add them, but they'd complicate the compiler. For now, Kō keeps it simple.

---

The result is pattern matching that's simple, efficient, and predictable. You write a match expression, the compiler generates a comparison chain, LLVM optimizes it, and you get native code. No hidden costs, no surprising behavior.

Pattern matching is the heart of Kō's control flow. The compilation strategy is straightforward: extract the tag, compare, bind, merge. LLVM handles the optimization. The hard parts are the LLVM gotchas — unreachable blocks, phi node types, type tag heuristics. But once you understand them, the rest is easy.

If you've ever wondered how pattern matching compiles to machine code, now you know. It's just comparisons and branches. The rest is details.

---

*Kō (光) means "light" in Japanese. Pattern matching is how Kō sees the world — one shape at a time.*
