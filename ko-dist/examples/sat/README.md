# sat — DPLL SAT solver

A complete SAT solver (unit propagation, pure-literal elimination,
recursive splitting) plus a CNF generator for graph coloring:

- `sat.ko` — solver over flat `List Int` CNF (clauses are literal runs
  terminated by `0`), an independent model checker, and a `kcolorComplete`
  generator that emits coloring CNF for complete graphs
- `main.ko` — test suite: unit clauses, contradictions, pigeonhole 3→2,
  K₃ 2-/3-coloring, and K₄ 3-coloring (UNSAT, needs real search)

Run it:

```bash
ko ko-zig/src/examples/sat/main.ko
```

Every SAT result is machine-checked by the in-Ko verifier (`True` on the
output lines). The solver returns an `Outcome` ADT carrying the model and
a decision count, so you can see unit propagation doing the heavy lifting
(K₄ 3-coloring refutes in 13 decisions).
