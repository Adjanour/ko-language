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

## Stuff we made

- **vscode extension** — syntax highlighting, keyword completion, hover docs. install from `vscode-ko/ko-language-0.1.0.vsix`
- **tree-sitter grammar** — `tree-sitter-ko/` for parsing and highlighting
- **formal grammar** — `GRAMMAR.md` has the EBNF spec
- **C codegen** — compiles to C99, fast execution

## TODO

- [ ] Port to rust or C
- [ ] Closures / higher order functions  
- [ ] Type inference
- [ ] Exhaustive pattern match checking
- [ ] Stream/video series on the whole journey
