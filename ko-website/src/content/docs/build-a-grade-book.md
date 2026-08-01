---
title: "Install Kō and Build Your First Program"
description: "Set up the Kō toolchain and write a small grade-book program, learning records, ADTs, pattern matching, and recursion along the way."
---

Kō is a small functional language that compiles to native code via LLVM: no parentheses around function calls, indentation-based blocks, Hindley-Milner type inference, and pattern matching instead of `if`-chains for control flow. This post gets Kō running on your machine, then builds one small, complete program (a grade book) to introduce the pieces you'll use in almost every Kō program: records, algebraic data types, pattern matching, and recursion.

Kō is **alpha software**. Expect rough edges; we'll call them out where they matter.

## Installing Kō

### Option 1: pre-built folder (fastest)

```bash
git clone https://github.com/Adjanour/ko-language.git
cd ko-language
./build.sh
```

This produces a self-contained `ko-dist/` folder: the compiler, the standard library, and example programs, with nothing installed system-wide. Try it:

```bash
echo 'fn main = println "Hello, Kō!"' > hello.ko
./ko-dist/ko hello.ko
```

### Option 2: build from source

You'll need [Zig](https://ziglang.org/download/) 0.17+ and LLVM 22.

```bash
# Debian/Ubuntu
sudo apt install llvm-22-dev zlib1g-dev

# Arch
sudo pacman -S llvm zlib
```

```bash
git clone https://github.com/Adjanour/ko-language.git
cd ko-language/ko-zig
zig build
```

The compiler lands at `zig-out/bin/ko`. Check it worked:

```bash
zig-out/bin/ko --version
```

From here on, this post just calls the binary `ko`; substitute `./ko-dist/ko` or `zig-out/bin/ko` for whichever way you installed it.

## Hello, Kō

Every Kō program needs a `main`:

```ko
fn main =
  println "Hello, Kō!"
```

Run it directly, there's no separate build step for quick iteration:

```bash
ko hello.ko
```

```
"Hello, Kō!"
```

A few things to notice immediately:

- **No parentheses for calls.** `println "Hello, Kō!"`, not `println("Hello, Kō!")`.
- **Indentation defines the body.** `main`'s body is whatever's indented under it.
- **Strings print with quotes.** `println` shows values the way you'd type them back into source, so a string prints with its quotes attached.

## The shape of Kō

Before building something real, four ideas you'll lean on constantly:

**Functions** take arguments without parentheses or commas, and application is just juxtaposition:

```ko
fn add x y = x + y

fn main =
  println (add 1 2)  # 3
```

**Everything is immutable by default.** `let` introduces a name, not a reassignable variable:

```ko
fn main =
  let x = 10
  println x
```

**`type` defines data**, either a plain record or a tagged union (an ADT); constructors are capitalized to distinguish them from ordinary values:

```ko
type Point = { x: Int, y: Int }
type Color = Red | Green | Blue
```

**`match` replaces most `if`-chains** once you're branching on the *shape* of data rather than a boolean:

```ko
fn name c =
  match c
    | Red => "red"
    | Green => "green"
    | Blue => "blue"
```

That's enough to build something.

## Building a grade book

We'll model a small class roster, compute an average, and print a letter grade per student. Along the way this introduces records, a hand-rolled linked list, and recursive functions over it: the standard toolkit for anything list-shaped in Kō today.

### Modeling a student

A record is the natural fit for one row of data:

```ko
type Student = { name: String, score: Int }
```

Construct one by naming the fields:

```ko
let ama = Student { name = "Ama", score = 92 }
```

and read a field back with dot access: `ama.name`, `ama.score`.

### A list of students

Kō doesn't have list-literal syntax (`[1, 2, 3]`) yet. The idiomatic way to represent a sequence today is to define your own linked-list type, which also happens to be the clearest way to *learn* what pattern matching and recursion are doing under the hood:

```ko
type List a = Cons a (List a) | Nil
```

Read this as: a `List a` is either `Nil` (empty) or `Cons` of one element and the rest of the list. It's generic: the `a` works for `List Student`, `List Int`, whatever you `Cons` together:

```ko
let roster =
  Cons (Student { name = "Ama", score = 92 })
  (Cons (Student { name = "Kojo", score = 76 })
  (Cons (Student { name = "Efua", score = 88 }) Nil))
```

One gotcha worth flagging up front: Kō's parser currently trips over constructor calls nested across *multiple* lines like the one above. Build the pieces with `let` first and keep each `Cons` on one line instead:

```ko
fn main =
  let ama = Student { name = "Ama", score = 92 }
  let kojo = Student { name = "Kojo", score = 76 }
  let efua = Student { name = "Efua", score = 88 }
  let roster = Cons ama (Cons kojo (Cons efua Nil))
```

### Recursion over the list

`total` and `count` both follow the same shape: match on whether the list is `Cons` (peel off one element, recurse on the rest) or `Nil` (base case).

```ko
fn total xs =
  match xs
    | Cons s rest => s.score + total rest
    | Nil => 0

fn count xs =
  match xs
    | Cons _ rest => 1 + count rest
    | Nil => 0

fn average xs =
  total xs / count xs
```

`_` in the `count` pattern means "there's a value here, I don't care what it is." This is the pattern you'll reuse for almost any list-processing function in Kō: match `Cons`, do something with the head, recurse on the tail; match `Nil`, stop.

### Classifying a score

Kō's `match` doesn't yet support guard clauses (`| n if n >= 90 => ...`), so a threshold-based classification reads more naturally as a plain `if`/`else` chain:

```ko
fn grade score =
  if score >= 90 then "A"
  else if score >= 80 then "B"
  else if score >= 70 then "C"
  else "F"
```

### Putting it together

```ko
type Student = { name: String, score: Int }
type List a = Cons a (List a) | Nil

fn total xs =
  match xs
    | Cons s rest => s.score + total rest
    | Nil => 0

fn count xs =
  match xs
    | Cons _ rest => 1 + count rest
    | Nil => 0

fn average xs =
  total xs / count xs

fn grade score =
  if score >= 90 then "A"
  else if score >= 80 then "B"
  else if score >= 70 then "C"
  else "F"

fn main =
  let ama = Student { name = "Ama", score = 92 }
  let kojo = Student { name = "Kojo", score = 76 }
  let efua = Student { name = "Efua", score = 88 }
  let roster = Cons ama (Cons kojo (Cons efua Nil))

  println ama.name
  println (grade ama.score)
  println kojo.name
  println (grade kojo.score)
  println efua.name
  println (grade efua.score)

  println (average roster)
  println (grade (average roster))
```

```bash
ko gradebook.ko
```

```
"Ama"
"A"
"Kojo"
"C"
"Efua"
"B"
85
"B"
```

### A note on that `main`-only printing

You'll notice every `println` above happens directly in `main`, on a value built right there, not inside a separate helper function that's handed the student as a parameter. That's not a style preference; it currently matters. Kō's alpha compiler decides how to print a value using type information resolved at compile time, and that resolution doesn't yet reliably carry through a generic function parameter: a helper like `fn show_name s = println s.name` will compile, but prints garbage instead of the name. It's a known limitation of the current type-tag mechanism (tracked in the [project's known issues](https://github.com/Adjanour/ko-language#known-issues-v020-alpha)), not something wrong in your program. Until it's fixed, keep the `println` calls for a piece of data in the same function where that data was constructed, the way the example above does.

### Bonus: compile-time evaluation

Kō can evaluate pure functions at compile time with `comptime`. The computation happens during compilation, and the result gets baked into the binary as a constant:

```ko
comptime fn factorial n =
  if n == 0 then 1 else n * factorial (n - 1)

fn main =
  let x = comptime factorial 5
  println x  # 120, computed when you compiled, not when you ran it
```

### Bonus: the pipe operator

`|>` reads left-to-right, which is often easier to follow than nested calls once you're chaining more than one transformation:

```ko
fn main =
  println (92 |> grade)  # same as println (grade 92)
```

## Where to go next

- [Tutorial](/docs/tutorial) for a fuller guided walkthrough of the language, concept by concept
- [Language Reference](/docs/reference) for the complete syntax
- The [GitHub repo](https://github.com/Adjanour/ko-language) for known issues, source, and to file bugs. Kō is alpha software built in the open, and issues are genuinely useful.

Kō doesn't have list literals, string concatenation, or match guards yet, and a few corners like the one above will surprise you. If you hit one, the known-issues list is the first place to check, and a bug report is always welcome.
