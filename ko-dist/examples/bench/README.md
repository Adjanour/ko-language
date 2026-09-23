# bench — multifile benchmark program

Five modules exercising ADTs, pattern matching, higher-order functions,
recursion, records, refs, pipes, partial application, and `Result`:

- `ast.ko` — expression trees (`eval`, const-folding `simplify`, `show`)
  and a binary search tree
- `arith.ko` — number theory: gcd, factorial, fibonacci, primes, collatz
- `listx.ko` — merge sort, sieve of Eratosthenes, folds over `std.List`
- `shapes.ko` — geometric shapes over `Float` (dotted operators)
- `main.ko` — driver (records live here; see below)

Run it:

```bash
ko ko-zig/src/examples/bench/main.ko
```

## Portability notes (ko 0.3.x)

These reflect real compiler gaps; each is linked to an issue:

- Constructors can't be used qualified (`ast.Add` fails) — import them
  selectively or wrap them in maker functions.
- Records must be defined and used in the same file (#49).
- `List Float` / `List String` matching crashes codegen (#50) — this
  program only matches on `List Int`.
- Don't pass bare qualified values (`mod.fn` with no call) — LIR
  lowering rejects them (#48). Eta-expand instead.
- The `?` operator mis-infers against the builtin `Result` (#51) —
  this program matches on `Result` explicitly.
