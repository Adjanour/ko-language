# Kō Data Structures

> **Status:** Design Draft
> **Date:** 2026-08-01
> **Research:** Rust Vec/HashMap, Go slice/map, Zig ArrayList/StringHashMap, OCaml Array

---

## 1. Current State

### List (Linked List)

Defined in `std/List.ko`:

```ko
type List a = Cons a (List a) | Nil
```

25+ operations: `head`, `tail`, `map`, `filter`, `foldl`, `foldr`, `reverse`, `append`, `take`, `drop`, etc.

Each `Cons` cell is a heap-allocated constructor: `[ i64 tag | i64 head | i64 tail ]`.

**Characteristics:**
- O(1) prepend (`Cons x xs`)
- O(n) append (`append xs ys`)
- O(n) index (`nth i xs`)
- O(1) head/tail
- No mutation — purely functional

### Tuples

Heap-allocated arrays of `i64`:

```ko
let pair = (1, "hello")
let triple = (1, 2.0, true)
pair.0    # 1
pair.1    # "hello"
```

**Characteristics:**
- Fixed size at creation
- Heterogeneous types
- O(1) access
- Heap-allocated (no stack tuples)

### Records

Heap-allocated structs with named fields:

```ko
type Point = { x: Int, y: Int }

let p = Point { x = 1, y = 2 }
p.x    # 1
p.y    # 2
```

**Characteristics:**
- Named fields
- Fixed set of fields
- O(1) access
- Heap-allocated

### What's Missing

| Data Structure | Use Case | Status |
|---------------|----------|--------|
| Array | Contiguous mutable sequence | Missing |
| Map | Key-value lookup | Missing |
| Set | Unique elements | Missing |
| Queue | FIFO operations | Missing |
| Deque | Double-ended queue | Missing |
| Stack | LIFO operations | Missing |

---

## 2. Design Principles

1. **Practical first.** CLI tools and compilers need arrays and maps more than they need immutable persistent structures.

2. **Mutable by default.** Kō already has `ref` for mutation. Arrays and maps should be mutable for performance. Immutable variants can be added later.

3. **RC-friendly.** All heap-allocated structures participate in reference counting. This means no cycles (documented limitation) but predictable memory behavior.

4. **Simple representation.** Prefer flat, contiguous layouts over pointer-heavy structures. Cache-friendly for the common cases.

5. **Compose with existing types.** `Map` should work with any hashable type. `Array` should work with any type.

---

## 3. Array Type

### Representation

```c
typedef struct {
  i64 refcount;
  i64 length;      // current number of elements
  i64 capacity;    // allocated slots
  i64 data[];      // contiguous i64 values
} KoArray;
```

All elements are `i64` (the tagged representation). For typed arrays, the codegen knows the element type and generates appropriate access code.

### Syntax

```ko
# Literal syntax
let arr = [1, 2, 3, 4, 5]
let arr = ["hello", "world"]
let arr = []               # empty array

# Constructor syntax
let arr = Array.make 10 0           # 10 zeros
let arr = Array.init 10 (\i -> i * 2)  # [0, 2, 4, ..., 18]
let arr = Array.fromList xs         # from linked list
```

### Operations

```ko
# === Creation ===
Array.make : Int -> a -> Array a              # n copies of default value
Array.init : Int -> (Int -> a) -> Array a    # init from index function
Array.fromList : List a -> Array a

# === Access ===
Array.get : Array a -> Int -> a               # O(1), panics on out-of-bounds
Array.getOr : a -> Array a -> Int -> a        # with default
Array.length : Array a -> Int                 # O(1)
Array.isEmpty : Array a -> Bool

# === Mutation ===
Array.set : Array a -> Int -> a -> Unit       # O(1), panics on out-of-bounds
Array.push : Array a -> a -> Unit             # amortized O(1) append
Array.pop : Array a -> Maybe a                # remove and return last
Array.insert : Array a -> Int -> a -> Unit    # O(n) insert at index
Array.remove : Array a -> Int -> Unit         # O(n) remove at index
Array.clear : Array a -> Unit                 # set length to 0

# === Search ===
Array.contains : a -> Array a -> Bool        # O(n)
Array.findIndex : (a -> Bool) -> Array a -> Maybe Int
Array.indexOf : a -> Array a -> Maybe Int

# === Transform ===
Array.map : (a -> b) -> Array a -> Array b
Array.filter : (a -> Bool) -> Array a -> Array a
Array.foldl : (b -> a -> b) -> b -> Array a -> b
Array.foldr : (a -> b -> b) -> b -> Array a -> b
Array.reverse : Array a -> Array a
Array.sort : Array a -> Array a
Array.sortWith : (a -> a -> Int) -> Array a -> Array a

# === Conversion ===
Array.toList : Array a -> List a
Array.slice : Array a -> Int -> Int -> Array a  # sub-array [start, end)
Array.concat : Array a -> Array a -> Array a
```

### Growth Strategy

When `push` exceeds capacity, reallocate with doubled capacity:

```c
void ko_array_push(KoArray* arr, i64 value) {
  if (arr->length >= arr->capacity) {
    i64 new_capacity = arr->capacity * 2;
    if (new_capacity < 8) new_capacity = 8;
    arr = realloc(arr, sizeof(KoArray) + new_capacity * sizeof(i64));
    arr->capacity = new_capacity;
  }
  arr->data[arr->length++] = value;
}
```

This gives amortized O(1) push.

### Codegen

`Array` is a builtin type. The compiler generates:
- `ko_array_make(len, default)` — allocate and fill
- `ko_array_get(arr, index)` — bounds check + load
- `ko_array_set(arr, index, value)` — bounds check + store
- `ko_array_push(arr, value)` — bounds check + realloc if needed + store
- `ko_array_length(arr)` — load length field

---

## 4. Map Type

### Representation

Hash map with open addressing or separate chaining.

```c
typedef struct {
  i64 refcount;
  i64 length;       // number of entries
  i64 capacity;     // number of buckets
  i64* keys;        // array of i64 key values
  i64* values;      // array of i64 value values
  i32* occupied;    // bitmap: is this slot occupied?
} KoMap;
```

### Hashing

A builtin `hash : a -> Int` function that works on:

| Type | Hash |
|------|------|
| Int | Identity (or murmur3 mixing) |
| Float | Bit pattern (after ensuring -0.0 == 0.0 and NaN == NaN) |
| Bool | 0 or 1 |
| Char | Byte value |
| String | FNV-1a hash of bytes |
| Tuple | Hash composition (hash each element, combine) |
| Constructor | Hash of tag + fields |
| Unit | 0 |

```c
i64 ko_hash(i64 val, i32 type_tag) {
  switch (type_tag) {
    case TAG_INT: return val;
    case TAG_FLOAT: { /* bit mixing */ }
    case TAG_BOOL: return val ? 1 : 0;
    case TAG_CHAR: return val;
    case TAG_STRING: { /* FNV-1a */ }
    case TAG_UNIT: return 0;
    case TAG_CONSTRUCTOR: { /* hash tag + fields */ }
    case TAG_TUPLE: { /* hash elements */ }
    default: return val;  // fallback: use raw value
  }
}
```

### Syntax

```ko
# Literal syntax
let m = {"name": "Alice", "age": 30, "active": true}
let m = {}               # empty map

# Constructor syntax
let m = Map.new ()
let m = Map.fromList [("name", "Alice"), ("age", "30")]
```

### Operations

```ko
# === Creation ===
Map.new : Map k v                              # empty map
Map.fromList : List (k, v) -> Map k v
Map.fromListWith : (v -> v -> v) -> List (k, v) -> Map k v  # merge function for duplicate keys

# === Access ===
Map.get : k -> Map k v -> Maybe v
Map.getOr : v -> k -> Map k v -> v             # with default
Map.containsKey : k -> Map k v -> Bool
Map.containsValue : v -> Map k v -> Bool
Map.length : Map k v -> Int
Map.isEmpty : Map k v -> Bool

# === Mutation ===
Map.set : k -> v -> Map k v -> Unit            # insert or update
Map.delete : k -> Map k v -> Unit              # remove key
Map.update : k -> (Maybe v -> Maybe v) -> Map k v -> Unit  # update with function
Map.clear : Map k v -> Unit

# === Iteration ===
Map.keys : Map k v -> List k
Map.values : Map k v -> List v
Map.toList : Map k v -> List (k, v)
Map.foldl : (b -> k -> v -> b) -> b -> Map k v -> b
Map.forEach : (k -> v -> Unit) -> Map k v -> Unit

# === Set operations ===
Map.union : Map k v -> Map k v -> Map k v     # merge (right overwrites left)
Map.intersection : Map k v -> Map k v -> Map k v
Map.difference : Map k v -> Map k v -> Map k v  # keys in first but not second
```

### Collision Handling

Use separate chaining with linked lists. Each bucket is a `List (k, v)`:

```c
typedef struct {
  i64 refcount;
  i64 length;
  i64 capacity;
  i64* buckets;     // array of List pointers
} KoMap;
```

When `length / capacity > 0.75`, double the capacity and rehash.

### Codegen

`Map` is a builtin type. The compiler generates:
- `ko_map_new()` — allocate empty map
- `ko_map_get(map, key)` — hash key, search bucket, return Maybe
- `ko_map_set(map, key, value)` — hash key, insert/update, resize if needed
- `ko_map_delete(map, key)` — hash key, remove from bucket
- `ko_hash(val, type_tag)` — compute hash for any value

---

## 5. Set Type

Set is implemented as `Map k Unit` internally. No separate implementation needed.

```ko
type Set a = Set (Map a ())

# === Creation ===
Set.empty : Set a
Set.singleton : a -> Set a
Set.fromList : List a -> Set a

# === Operations ===
Set.contains : a -> Set a -> Bool
Set.add : a -> Set a -> Unit
Set.remove : a -> Set a -> Unit
Set.size : Set a -> Int
Set.isEmpty : Set a -> Bool

# === Set operations ===
Set.union : Set a -> Set a -> Set a
Set.intersection : Set a -> Set a -> Set a
Set.difference : Set a -> Set a -> Set a
Set.isSubset : Set a -> Set a -> Bool
Set.isSuperset : Set a -> Set a -> Bool

# === Conversion ===
Set.toList : Set a -> List a
Set.fromList : List a -> Set a
```

---

## 6. Relationship Between List and Array

Both `List` and `Array` serve the "sequence" role, but with different tradeoffs:

| Operation | List | Array |
|-----------|------|-------|
| Prepend | O(1) | O(n) |
| Append | O(n) | O(1) amortized |
| Index | O(n) | O(1) |
| Length | O(n) | O(1) |
| Iteration | O(n) | O(n) (faster cache) |
| Memory | Per-element heap | Contiguous heap |
| Immutability | Native | Via ref |

**When to use which:**

- **List:** Functional patterns (map/fold on immutable data), small sequences, pattern matching on structure (`Cons x xs`)
- **Array:** Random access, mutation, building up data incrementally, large sequences

**Conversion:**

```ko
Array.toList : Array a -> List a    # O(n)
List.toArray : List a -> Array a    # O(n)
```

Both are O(n). The conversion is explicit — no implicit coercion.

---

## 7. Future Data Structures

### Deque (Double-Ended Queue)

For when you need O(1) prepend and append:

```ko
type Deque a = Deque (Array a) (Array a)  # front and back arrays

Deque.empty : Deque a
Deque.pushFront : a -> Deque a -> Unit
Deque.pushBack : a -> Deque a -> Unit
Deque.popFront : Deque a -> Maybe a
Deque.popBack : Deque a -> Maybe a
```

### Priority Queue

For scheduling, Dijkstra, etc.:

```ko
type PriorityQueue a = PriorityQueue (Array a)  # binary heap

PriorityQueue.empty : (a -> a -> Int) -> PriorityQueue a
PriorityQueue.push : a -> PriorityQueue a -> Unit
PriorityQueue.pop : PriorityQueue a -> Maybe a
```

### Rope (for large strings)

For programs that concatenate many strings (code generators, SQL builders):

```ko
type Rope = Leaf String | Branch Rope Rope Int  # length

Rope.empty : Rope
Rope.append : Rope -> Rope -> Rope
Rope.toString : Rope -> String
Rope.length : Rope -> Int
```

These are library concerns, not language concerns. Implement in `std.collections`.

---

## 8. Implementation Phases

### Phase 1: Array (v0.3.0)

- [ ] `KoArray` struct in runtime
- [ ] `ko_array_make`, `ko_array_get`, `ko_array_set`, `ko_array_push`, `ko_array_length`
- [ ] Codegen for `[1, 2, 3]` array literal syntax
- [ ] RC for `KoArray` (recursive decref for elements)
- [ ] `Array.toList` and `List.toArray` conversion

### Phase 2: Map (v0.3.0)

- [ ] `hash` builtin for all value types
- [ ] `KoMap` struct in runtime
- [ ] `ko_map_new`, `ko_map_get`, `ko_map_set`, `ko_map_delete`
- [ ] Codegen for `{"key": value}` map literal syntax
- [ ] RC for `KoMap` (recursive decref for keys and values)

### Phase 3: Set & Higher-Order (v0.3.0)

- [ ] `Set` as thin wrapper over `Map`
- [ ] `Array.map`, `Array.filter`, `Array.foldl`
- [ ] `Map.foldl`, `Map.forEach`

### Phase 4: Advanced (v0.4.0)

- [ ] `Deque` type
- [ ] `PriorityQueue` type
- [ ] `sort` for Array (merge sort or introsort)
- [ ] `groupBy` for Map

---

## 9. Examples

### Array Usage

```ko
fn main =
  let arr = [3, 1, 4, 1, 5, 9]
  Array.push arr 2
  println (Array.length arr)    # 7
  
  let sorted = Array.sort arr
  println sorted                # [1, 1, 2, 3, 4, 5, 9]
  
  let evens = Array.filter (\x -> x % 2 == 0) arr
  println evens                 # [2, 4]
  
  let sum = Array.foldl (+) 0 arr
  println sum                   # 25
```

### Map Usage

```ko
fn main =
  let scores = {"Alice": 95, "Bob": 87, "Carol": 92}
  
  match Map.get "Alice" scores
    Just score -> println "Alice: ${to_string score}"
    Nothing -> println "Alice not found"
  
  Map.set scores "Dave" 78
  Map.delete scores "Bob"
  
  println (Map.keys scores)    # ["Alice", "Carol", "Dave"]
  println (Map.length scores)  # 3
```

### Set Usage

```ko
fn main =
  let s1 = Set.fromList [1, 2, 3, 4]
  let s2 = Set.fromList [3, 4, 5, 6]
  
  println (Set.toList (Set.union s1 s2))        # [1, 2, 3, 4, 5, 6]
  println (Set.toList (Set.intersection s1 s2))  # [3, 4]
  println (Set.toList (Set.difference s1 s2))    # [1, 2]
  println (Set.contains 3 s1)                    # true
```

---

*This document is a living design draft. It will be updated as implementation progresses.*
