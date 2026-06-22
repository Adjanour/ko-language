# Kō Programs

> Idiomatic Kō examples in the current syntax.

## Small Functions

```ko
pub fn add x y = x + y

pub fn square x = x * x
```

## ADTs And Records

```ko
type Expr =
  Num Int
  | Var String
  | Add Expr Expr
  | Let String Expr Expr

type Binding = {
  name : String,
  value : Int
}
```

## Matching

```ko
pub fn eval expr env =
  match expr
    Num n -> n
    Var name -> lookup name env
    Add left right -> eval left env + eval right env
    Let name value body ->
      let next = extend env name (eval value env)
      eval body next
```

## Records

```ko
let binding = Binding { name = "count", value = 1 }

match binding
  Binding { name, .. } -> println name
```

## Mutation

```ko
let counter = ref 0
counter := !counter + 1
```

## Application And Pipes

```ko
numbers
  |> map (\x -> x + 1)
  |> filter (\x -> x > 0)
```

## Named Arguments

```ko
http-request ~method:"GET" ~url:base-url
```

## Block Style

```ko
pub fn main =
  let expr = Add (Num 1) (Num 2)
  println (eval expr empty-env)
```
