## 0.80.2 - 2026-09-18

Two fixes from the interfaces releases.

### A pipeline indented a stage that wrapped two spaces too deep

The closing bracket did not line up with the one it opened.

```
-- before                      -- now
  [                              [
      (r.draft, "a draft"),        (r.draft, "a draft"),
      (bad, "below the floor")     (bad, "below the floor")
    ]                            ]
    |> List.filter_map f         |> List.filter_map f
```

Every stage now starts at the column the pipeline starts at. This reformats
wrapped pipelines across the standard library, the examples and the tools.
Run `wand f` once and your own files settle the same way.

### The rehearse lens ran in a terminal of its own, which closed with the command

A gate script that exits non-zero read as a failure to launch, and the output
went before anyone could read it.

The lens now runs in an ordinary terminal. The prompt comes back, the output
stays, and running it again is one keystroke. The extension is 0.3.2.
