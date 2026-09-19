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

### The rehearse lens reported a blocked script as a failure to launch

A gate script exits non-zero to say that it blocks. VS Code reads that as a
launch failure and hides what wand printed. The lens now reports the exit
status and leaves the output in the terminal. A `wand` that cannot be found
still fails. The extension is 0.3.2.
