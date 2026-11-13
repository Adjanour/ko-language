# Kō Compiler Events and Cache Specification
## Status

Draft. This defines the target compiler protocol and artifact cache.

## Goals

- Let build tools and the LSP observe compilation without parsing terminal output.
- Make cache hits and misses explainable.
- Reuse completed compiler work across processes only when all inputs are known.
- Keep compilation deterministic and safe when compile-time execution is present.

## Workspace

A workspace is one isolated compilation request. It contains:

- root modules;
- package roots and dependency roots;
- target triple;
- optimization and feature flags;
- output requests;
- compiler and standard-library versions.

Workspaces do not share mutable compilation state. They may share immutable cached artifacts.

## Event stream

The compiler emits ordered events for one workspace:

```text
CompilationStarted(workspace_id, configuration_hash)
ModuleDiscovered(module_id, source_path)
ModuleResolved(module_id, imports, interface_dependencies)
ModuleTypechecked(module_id, interface_hash)
ComptimeEvaluated(action_id, inputs, result_hash)
CacheHit(stage, key, artifact_hash)
CacheMiss(stage, key, reason)
ArtifactProduced(kind, path, hash)
Diagnostic(diagnostic)
CompilationFinished(status, timings, cache_stats)
```

The event stream is append-only. A compile-time handler may use the compiler API to mutate the active program. A mutation records the module, nodes, and compiler phase that it changes. The compiler invalidates affected stages and resumes from the earliest invalid stage.

Build configuration is supplied before `CompilationStarted`. A later build request creates a new workspace.

## Cache model

The persistent cache is content-addressed. An artifact is reusable only when its complete input key matches.

For a module interface, the key includes:

```text
compiler build ID
language version
target triple
relevant flags and features
module identity
module source hash
imported interface hashes
standard-library interface hash
observed compile-time input hashes
```

Other stages add their own inputs. For example, an object-file key also includes the typed-HIR hash, representation-contract version, LLVM version, and code-generation options.

The cache stores immutable serialized artifacts. It never stores raw pointers, memory addresses, open handles, or temporary paths. An artifact touched by an opaque compile-time action is not persisted or reused.

## Cache artifacts

The initial cache may contain:

- parsed module data;
- resolved module data;
- serialized module interfaces;
- typed HIR;
- specialized-function artifacts;
- LIR;
- LLVM bitcode or object files.

Caching starts with module interfaces and object files. Later stages are cached only after their serialization format and dependency key are stable.

## Invalidation

There is no timestamp-based validity rule. A cache artifact is valid only when its content-addressed key matches.

Changing a module body without changing its public interface may preserve cache hits for dependent modules. Changing an exported type, constructor layout, public function type, observed compile-time input, target, feature, or compiler version invalidates affected artifacts. A live-AST mutation invalidates all artifacts that depend on the changed nodes.

The compiler must state a miss reason in the event stream, such as `source_changed`, `import_interface_changed`, `target_changed`, `comptime_input_changed`, `opaque_comptime`, `ast_mutated`, or `compiler_changed`.

## Failure handling

Failed compilation artifacts are not reused as successful artifacts. The compiler may cache diagnostics later, but a diagnostic cache must be invalidated by the same complete input key and must never suppress fresh diagnostics.

If a cached artifact cannot be decoded or fails validation, the compiler discards it, emits `CacheMiss(..., corrupt_artifact)`, and rebuilds the stage.

## Non-goals

- A long-lived mutable compiler daemon is not required for the first version.
- Cache reuse is not a replacement for a correct module graph.
- Fine-grained incremental typechecking is not required before stable module interfaces exist.
