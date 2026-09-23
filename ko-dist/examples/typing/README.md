# typing — static type annotations end to end

Fully signed modules: parameter, return, `let`, arrow (`Int -> Int`),
applied (`List Int`), and record annotations, checked across module
boundaries:

- `talg.ko` — arithmetic with complete signatures, including
  higher-order (`applyTwice`, `compose`, `makeAdder`)
- `tlist.ko` — `List Int` algorithms over `std.List`
- `tmain.ko` — records, a custom `Color` ADT, builtin `Result`, and
  arrow-typed `let`s wiring it all together
- `errors/` — programs that must FAIL `ko --check`:
  - `n1.ko` — wrong return type
  - `n2.ko` — argument type mismatch at the call site
  - `n3.ko` — lying `let` annotation
  - `n4.ko` — named returns (`-> d : Bool`) are not valid syntax

Run it:

```bash
ko ko-zig/src/examples/typing/tmain.ko
for f in ko-zig/src/examples/typing/errors/*.ko; do ko --check "$f"; done  # all must fail
```

## Portability notes (ko 0.3.x)

- The builtin `Result` is **error-first** (`Result String Int`), unlike
  the ok-first order in the docs (#54).
- Nullary functions can't be referenced as values — `origin`/`mkRed`
  take an explicit dummy parameter (#48).
- Only single-parameter lambdas returning non-`String` are safe with
  higher-order stdlib calls; multi-parameter closures (#44) and
  non-`Int` list payloads (#50) crash codegen.
