# Kō Compile-Time Execution Specification
## Status

Draft. This specifies the target behavior of `comptime`. It does not grant new file, process, or network access to the current compiler.

## Goals

- Run ordinary Kō expressions while compiling.
- Make generated values and declarations deterministic.
- Record every external input so compiler caching stays correct.
- Keep compile-time failures understandable and bounded.

## Execution model

`comptime` evaluates a Kō expression during compilation and replaces the expression with its result.

```ko
fn table = comptime makeTable 256
```

Compile-time execution uses a dedicated evaluator or VM. It does not execute generated host machine code and does not share mutable state with the compiler process.

The evaluator has its own heap and call stack. A compile-time allocation is not a runtime allocation unless its resulting value is embedded in the output program.

## Evaluation order

1. Parse source.
2. Resolve names needed by the compile-time expression.
3. Typecheck the expression.
4. Evaluate it in the compile-time evaluator.
5. Typecheck generated declarations, if any.
6. Continue ordinary compilation with the resulting typed program.

An expression may only run after its referenced declarations have been resolved and typechecked. A dependency cycle between compile-time actions is an error.

## Allowed results

The first version supports results that have a deterministic serializable representation:

- scalar values;
- strings and byte arrays;
- tuples, records, lists, and ADTs whose fields are supported results;
- type values;
- generated declarations produced through the compiler API.

Pointers, open files, sockets, process handles, allocator references, and compiler-internal objects cannot be compile-time results.

## Generated declarations

Compile-time code may generate declarations through the compiler API or mutate existing compiler AST nodes. A mutation runs in the active compilation workspace and is visible to later compiler stages.

Every generated or changed declaration must retain:

- generated declaration kind;
- generated name and scope;
- typed parameters and result type;
- source span of the generating action;
- stable generated ID.

After a mutation, the compiler invalidates the affected resolution, typechecking, HIR, and code-generation results. It then reruns the affected stages before using the changed program. The compiler owns parsing, name resolution, hygiene, and typechecking of generated declarations.

## Capabilities and external inputs

Compile-time code may read files and environment variables, use the clock and random-number generator, access the network, and launch processes. These operations do not require an advance declaration.

The compiler classifies each action for caching:

```text
pure       no external input or mutable compiler-program change
tracked    compiler-observed file or environment reads
opaque     network, process, clock, random input, untracked host access, or live-AST mutation
```

For tracked operations, the compiler records:

- action ID and source location;
- operation and normalized argument;
- content hash of the observed input;
- result hash;

The record is part of the cache key for every affected artifact. Opaque actions are allowed, but artifacts they affect are not reused from the persistent cache. The compiler emits an event that states why an artifact is non-cacheable.

## Limits and failures

Each workspace configures limits for execution time, memory, recursion depth, and generated declaration count. Exceeding a limit is a compile-time error with the action's source span and a compile-time stack trace.

Compile-time diagnostics use normal Kō diagnostic formatting. If a generated declaration fails to typecheck, the diagnostic includes both the generated location and the source location that generated it.

## Determinism

Pure and tracked actions must produce the same result for the same compiler version, target, flags, source, and observed inputs. Opaque actions may produce different results; they are allowed but make their affected artifacts non-cacheable.

## Non-goals

- Sharing mutable globals between compile-time and runtime execution.
