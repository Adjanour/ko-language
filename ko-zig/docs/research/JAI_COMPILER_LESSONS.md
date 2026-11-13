# What Kō Can Learn from Jai

## Evidence and limits

Jai is not publicly documented as a stable open-source compiler. The useful public descriptions are a community-maintained library wiki, a long-time Jai user's report, and OpenJai's reconstruction of the language design. They agree on the main ideas below, but implementation details and current behavior must be treated as unverified until a first-party Jai specification or compiler source is available.

This note separates what Kō can borrow from what Kō should not copy.

## 1. Modules: use a real module graph

Jai distinguishes importing a module from loading a file. Its community documentation describes `#import` as loading a module once and making it available through a namespace, while `#load` merges declarations from a file into the current scope. Modules are found through import directories; a module can be a file or a directory with a `module.jai` entry file. [Jai community: imports and loads](https://github-wiki-see.page/m/Jai-Community/Jai-Community-Library/wiki/Getting-Started)

The part to borrow is not Jai's exact syntax. It is the rule that the compiler owns module identity, loading, and dependency order.

For Kō:

- Add a resolver stage before typechecking.
- Give every loaded module a canonical identity: package name, canonical source path, content hash, and compiler/language version.
- Build an import graph before type inference. Typechecking should receive resolved modules, not open files by path during inference.
- Define import semantics precisely: imported names, qualified names, exports, duplicate imports, import cycles, and error locations.
- Compile a module once per compilation workspace. Multiple imports should reuse the same parsed and resolved module result.

Do not copy `#load`-style textual scope merging. Kō should retain module boundaries because they make names, incremental invalidation, diagnostics, and caching tractable.

## 2. Compile-time execution: use ordinary Kō code, but make inputs explicit

Jai's `#run` executes arbitrary code during compilation. The public community documentation says that this code can inspect or change globals and may need to wait until dependencies are ready; its `#run, stallable` form exists for such dependency scheduling. Jai also has code-as-data facilities (`#code`) and compile-time AST inspection. [Jai community: metaprogramming](https://github-wiki-see.page/m/Jai-Community/Jai-Community-Library/wiki/Metaprogramming)

The idea to borrow is that compile-time programs should be useful enough to generate data, validate programs, configure builds, and generate code. The part not to borrow is unrestricted ambient authority.

For Kō:

- Keep `comptime` as normal Kō code evaluated by a dedicated compile-time evaluator or VM.
- Start with pure computation, type values, deterministic code generation, and compile-time assertions.
- Make every external input explicit: files read, environment variables, target triple, feature flags, compiler version, and generated source.
- Give compile-time evaluation a separate heap, limits for time, memory, recursion, and generated code size, and useful stack traces.
- Require a declared capability before compile-time code reads a file, accesses the network, launches a process, or retains side effects in the output program.
- Record the input hashes and output hash of each compile-time action. This is required for correct caching.

Kō should not expose mutation of the compiler's live AST as its first metaprogramming interface. Start with typed data and controlled generated declarations or expressions. AST rewriting can be added later only if source locations, hygiene, typechecking, termination, and cache keys are fully specified.

## 3. Build configuration: borrow the message protocol, not the hidden control flow

Jai's build metaprogram can create a compilation workspace and receive messages from the compiler. Community material describes events for files, imports, phases, errors, and completion; OpenJai's implementation note reconstructs the same message-loop interface. [Jai build-message description](https://github-wiki-see.page/m/Jai-Community/Jai-Community-Library/wiki/Metaprogramming) [OpenJai implementation notes](https://github.com/withlang-dev/open-jai/blob/main/docs/OpenJai_implementation_notes.md)

This is useful because it treats the compiler as a service with observable state instead of a black-box command that only writes text to stdout.

For Kō, the first version should be a read-only event stream:

```text
CompilationStarted
ModuleDiscovered(module_id, path)
ModuleResolved(module_id, imports)
Typechecked(module_id)
ComptimeEvaluated(action_id, declared_inputs, output_hash)
ArtifactProduced(kind, path, hash)
Diagnostic(diagnostic)
CompilationFinished(status, timings, cache_stats)
```

The build driver may use these events to print progress, collect diagnostics, produce tooling data, or decide which named build target to request. It should not mutate the current compiler pass while that pass is running. Requests that change compilation should be declared before compilation starts: target, output kind, optimization level, module roots, features, and permitted compile-time capabilities.

This preserves the good part of Jai's approach—one language and one compiler protocol—without making compiler control flow impossible to reason about.

## 4. Caching and incremental compilation: correct the premise

The available Jai material describes a different strategy from “caching instead of incremental builds.” Jai is commonly described as recompiling the whole program quickly enough that it does not need fine-grained incremental compilation. A long-time Jai user reports fast whole-project rebuilds; a discussion of Jai's design makes the same claim but is not an official source. [Four Years of Jai](https://smarimccarthy.is/posts/2024-12-02-four-years-of-jai/) [Design discussion, lower confidence](https://news.ycombinator.com/item?id=34112685)

Kō should learn the principle, not copy the conclusion:

> Make a clean compile fast first. Add caching where the compiler has a complete, explicit dependency key. Do not introduce invalidation machinery before module and compile-time dependencies are well-defined.

Use two levels of reuse:

1. **In-process query reuse.** During one compiler or language-server session, memoize parsing, resolution, typechecking, HIR lowering, specialization, and code generation by explicit dependency keys. This supports editors and repeated builds.
2. **Persistent content-addressed artifacts.** Across processes, cache only results that can be keyed completely. A module result key must include source content hashes, imported interface hashes, compiler version, target, flags, standard-library version, and every declared compile-time input.

Do not cache raw AST pointers, runtime addresses, temporary filesystem paths, or results of undeclared I/O. Do not reuse a module merely because its source file has not changed; imported interfaces and compiler options are also inputs.

The cache is not a substitute for incremental compilation. It is a safe way to reuse completed work. Fine-grained invalidation can later be built on the same dependency graph, after Kō has stable module interfaces and deterministic compile-time execution.

## Recommended order for Kō

1. Implement a module graph and resolver with stable module IDs and cycle diagnostics.
2. Define a serializable module interface: exported names, types, constructor layouts, and public specialization requirements.
3. Make clean builds measurable and fast before adding persistence.
4. Add a content-addressed module-interface cache with traceable cache hit and miss reasons.
5. Add a restricted, deterministic `comptime` evaluator whose dependencies are declared and hashed.
6. Add build events and a small build API after the compilation model is stable.
7. Only then consider generated declarations, code-as-data, or compiler-directed build programs.

## Decision

Borrow Jai's integrated view: modules, compile-time work, and building belong to the language toolchain, not to unrelated scripts. Do not borrow its unrestricted compile-time authority or make Kō's pipeline re-entrant before the compiler can track dependencies, diagnostics, and cache keys.

Kō's version should be simpler: a resolved module graph, deterministic compile-time execution, an observable compiler event stream, and content-addressed reuse built on declared inputs.
