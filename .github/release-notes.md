## 0.80.0 - 2026-09-18

Interfaces: a contract on a module. Plus a compile cache fault that is in
0.79.0 and all earlier releases.

### Interfaces

An interface is a contract on a module: the functions that the module must
provide. It is the type you give a parameter that is a module.

```ocaml
-- ord.wand
interface Ranked 'a(top: 'a -> 'a -> 'a, bottom: 'a -> 'a -> 'a)

-- ints.wand
let ord = import ./ord

implement ord.Ranked Int =
  let top a b = if a > b then a else b;
  let bottom a b = if a < b then a else b

-- main.wand
let biggest (m: ord.Ranked Int) a b = m.top a b

biggest ints 3 7        -- 7
```

An interface takes any number of type parameters. An implementation is a run
of `let` bindings that a `;` separates. Each binding belongs to the module
that contains it.

Reach an imported interface through the module that declares it, as
`ord.Ranked`. The file that declares an interface writes the bare name.

A member declares the effects that it performs. An effect variable that no
argument names is an error.

### `Ord` is a built-in interface

The eleven ordered types implement it. Write it bare.

```ocaml
import Int
import Size

let biggest : Ord 'a -> 'a -> 'a -> 'a = fn m a b -> m.max a b

biggest Int 3 7          -- 7
biggest Size 4KB 100MB   -- 100MB
```

`Int.max`, `Int.min`, `Int.clamp` and `Int.between?` keep their types, their
documentation and their answers. `Ord` is not a module.

### `wand d` marks a member that implements an interface

It also aligns the colons.

```
$ wand d Int
Int.abs       : Int -> Int
Int.between?  : Int -> Int -> Int -> Bool [Ord]
Int.clamp     : Int -> Int -> Int -> Int [Ord]
Int.divmod    : Int -> Int -> (Int, Int)
Int.max       : Int -> Int -> Int [Ord]
Int.max_value : Int
```

The column resets at each module. `wand d --index` and `wand d <member>` read
the same way. `--index --json` adds `implements`, which is null for a member
that implements nothing.

### The compile cache kept a module after a module that it imports changed

`wand t` reported no error for code that does not typecheck.

```
dep.wand:  let n = 1        ->  let n = "x"
mid.wand:  let d = import ./dep
           let f () = d.n + 1
main.wand: let m = import ./mid
           m.f ()
```

`wand t main.wand` reported `Int`. The fault is in 0.79.0 and all earlier
releases.
