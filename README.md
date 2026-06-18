# Kō (kō)

Vibecoded a language by stealing ideas lol. The goal was to be minimal — like really minimal. Here's what i wanted:

No parens for function calls (just `add 1 2`), minimal indentation (only for function bodies), uppercase means constructors (`Just` vs `x`), `*` marks type slots (`type Maybe = Just * | Nothing`), ADTs as a first class thing, pattern matching with `match`, immutability by default (let bindings can't be reassigned), no type system (untyped, start simple), and compile to C for fast execution.

## What i actually learned

Ok so like i actually understand tokenization and parsing now. And grammar definition. I can go through and point out all the bs the llm/agent did there lol. But i had the ideas so that's what matters i think?

Still implementing the timeless jilox language 😅 so gonna finish that and some other plans first. Then maybe on a stream or series of videos port this to a better language and improve it with my newfound knowledge. I have always hated a blank slate btw.

Its codegen is in C btw. A choice i made. Also made it add tree-sitter for syntax highlighting and we wrote a vscode extension. Fun times ahead

## Quick start

```bash
python3 ko.py examples/01_hello.ko
python3 ko.py -e 'println "hello"'  # run inline
```

## Examples

```kō
// basic function
fn double x = x * 2

// pattern matching
type Maybe = Just * | Nothing

fn from-just default mx =
  match mx
    Just x -> x
    Nothing -> default

// lists
type List = Cons * * | Nil

fn sum xs =
  match xs
    Cons x rest -> x + sum rest
    Nil -> 0
```

## Standard Library

All functions return values (functional style).

### String ops
```kō
len "hello"           // 5
concat "a" "b"        // "ab"
char_at "abc" 1       // 'b'
substring "hello" 0 3 // "hel"
contains "hello" "ell" // true
to_upper "hello"      // "HELLO"
to_lower "HELLO"      // "hello"
trim "  x  "          // "x"
starts_with "hello" "he" // true
ends_with "hello" "lo"   // true
repeat "ha" 3         // "hahaha"
```

### Math ops
```kō
abs (-5)     // 5
min 3 7      // 3
max 3 7      // 7
pow 2 10     // 1024
sqrt 16      // 4
floor 3.7    // 3
ceil 3.2     // 4
mod 10 3     // 1
```

### Conversion & type checking
```kō
to_string 42      // "42"
to_int "123"      // 123
to_float 42       // 42.0
type_of 42        // "int"
is_int 42         // true
is_string "hello" // true
```

### I/O (functional — returns values)
```kō
read_line "name: "     // reads from stdin, returns string
read_file "foo.txt"    // returns file contents as string
write_file "foo.txt" "content"  // returns true/false
append_file "foo.txt" "more"    // returns true/false
run "ls -la"           // returns command output as string
get_env "HOME"         // returns env var or ""
args_count             // number of command line args
args_get 0             // get argv[0]
now                    // milliseconds since start
exit 0                 // exit with code
```

### Pure random (functional)
```kō
let r1 = random 12345 1 100   // random with seed
let next = seed               // get next seed
let r2 = random next 1 100    // chain it
```

## Stuff we made

- **vscode extension** — syntax highlighting, keyword completion, hover docs. install from `vscode-ko/ko-language-0.1.0.vsix`
- **tree-sitter grammar** — `tree-sitter-ko/` for parsing and highlighting
- **formal grammar** — `GRAMMAR.md` has the EBNF spec
- **C codegen** — compiles to C99, fast execution
- **standard library** — strings, math, I/O, type checking

## Design decisions

- **No parens** for function calls — `add 1 2` not `add(1, 2)`
- **Minimal indentation** — only for function bodies
- **Uppercase = constructors** — `Just` vs `x`
- **`*` marks type slots** — `type Maybe = Just * | Nothing`
- **Immutability by default** — let bindings can't be reassigned
- **I/O returns values** — functional style, no side effects in expressions
- **Pure randomness** — takes seed, returns (value, new_seed)
- **Compiles to C** — fast execution, easy to debug

## TODO

- [ ] Port to rust or C
- [ ] Closures / higher order functions  
- [ ] Type inference
- [ ] Exhaustive pattern match checking
- [ ] Stream/video series on the whole journey
