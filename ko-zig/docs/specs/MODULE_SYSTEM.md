# Kō Module System Specification
## Status

Draft. This defines the target module system. Current file-based imports are not required to meet this specification yet.

## Goals

- A module has one stable identity within a compilation workspace.
- An import has deterministic resolution rules.
- A module is parsed, resolved, and typechecked once per workspace.
- Errors identify both the importing source and the imported module.
- Module interfaces can be serialized and reused by the compiler cache.

## Terms

| Term | Meaning |
| --- | --- |
| Package | A named collection of Kō modules with one declared root directory. |
| Module path | A dot-separated logical name, such as `app.Json` or `std.List`. |
| Module | The declarations resolved from one module entry file. |
| Workspace | One isolated compilation request, including roots, target, flags, and compiler configuration. |
| Interface | The public names, types, constructors, and metadata exported by a module. |

## Module identity

A module ID is the tuple:

```text
(package name, module path, canonical source path, language version)
```

The canonical source path prevents two spellings of the same file from loading it twice. The package name and module path prevent unrelated packages with the same directory layout from colliding.

The compiler may use a content hash in cache keys, but source content alone is not a module identity. A module's package and logical name remain part of diagnostics, symbol names, and interfaces.

## Source layout

Each source file may declare its module path:

```ko
module app.Json
```

If a declared module path does not match the path selected by import resolution, compilation fails. The error reports the importing file, requested module path, resolved file, and declared path.

The standard library is package `std`. A user import never overrides a `std.*` module.

## Imports

Imports use logical module paths:

```ko
import std.List
import app.Json
import app.Json as Json
import app.Json { decode, encode }
```

The resolver supports these forms:

| Form | Names introduced into the importing module |
| --- | --- |
| `import a.B` | Namespace `B`. |
| `import a.B as C` | Namespace `C`. |
| `import a.B { x, y }` | Public names `x` and `y`. |

An import does not execute module initialization. It makes exported declarations available for resolution and typechecking.

## Resolution order

For `import a.B`, the resolver searches in this order:

1. the importing package's declared root;
2. declared dependency package roots;
3. the standard-library package when the path starts with `std`.

The resolver does not search the current working directory, arbitrary parent directories, or process environment paths. All package roots are supplied in workspace configuration.

The selected source file is deterministic. If two candidates match at the same resolution level, compilation fails rather than choosing one by filesystem order.

## Module graph

Before typechecking application code, the compiler builds an import graph from all root modules.

Each graph node has one of these states:

```text
unseen → loading → parsed → resolved → typechecked → failed
```

Re-entering a `loading` module is an import cycle. The compiler reports the full cycle path. A failed module remains failed for the rest of the workspace; later imports return the same diagnostic rather than loading it again.

Modules are typechecked in dependency order. A module may read an imported module's interface only after that interface has been produced successfully.

## Visibility

Declarations are private unless marked `pub`.

```ko
pub fn decode input = ...
fn parseToken input = ...
```

Only public declarations appear in a module interface. Importers cannot name private definitions, constructors, fields, or generated specializations.

## Module interface

A module interface contains:

- module ID and language version;
- exported names and their fully resolved types;
- public type definitions and constructor names;
- public record layouts required by importers;
- interface hash;
- declared compile-time dependencies that affect the interface.

The interface contains no process-local pointers or allocator addresses. It must be serializable.

## Required diagnostics

The resolver must diagnose:

- module not found;
- ambiguous module;
- declared module path mismatch;
- duplicate import alias;
- imported name not exported;
- duplicate imported name in one scope;
- import cycle;
- failed imported module.

Every import diagnostic includes the import location and, when available, the relevant location in the imported module.

## Non-goals

- Textual inclusion of one source file into another scope.
- Filesystem-path imports in source code.
- Runtime module loading.
- Implicit package discovery.
