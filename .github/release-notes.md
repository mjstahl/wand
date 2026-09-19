## 0.80.1 - 2026-09-18

Two editor faults from the interfaces release.

### The editor put every member of an implementation on one line

Each member reported the position of the block, not of its own `let`.

```
between? : ... | clamp : ... | max : ... | min : ...
implement Ord Int =
  let max a b = if a > b then a else b;
```

A member now gets a code lens above its own `let`.

### The VS Code extension did not know `interface` or `implement`

Both are declaration keywords now. The extension is 0.3.1.
