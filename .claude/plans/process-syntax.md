# Process Syntax Plan

Replace the `Process` module with two shell interpolation forms that cover all
scripting use cases cleanly.

## New syntax

### `$(cmd)` — happy path

Runs a shell command. Returns stdout as `String`. Raises on non-zero exit.

When used as a pipeline stage, accepts the left-hand value as stdin:

```
$(git log --oneline)                   -- standalone, no stdin
  |> String.lines
  |> List.filter (String.match? r/fix/)
  |> String.join "\n"
  |> $(grep -c ".")                    -- receives stdin from pipeline
```

Desugar:
- Standalone: `Process.run "cmd"`
- Pipeline stage: `fn stdin -> Process.run_stdin "cmd" stdin`

String interpolation works as expected:

```
let branch = $(git rev-parse --abbrev-ref HEAD)
let log    = $("git log --oneline -${count}")
```

### `$?(cmd)` — full control

Runs a shell command. Never raises. Returns a record:

```
{ stdout : String, stderr : String, code : Int }
```

Same stdin behaviour as `$()` — accepts piped input when used as a pipeline
stage.

```
let result = $?(git status)
match result.code with
| 0 -> result.stdout
| _ -> Error result.stderr
```

## Removing the `Process` module

The two new forms replace all current `Process` functions:

| Old                      | New              |
|--------------------------|------------------|
| `Process.run cmd`        | `$(cmd)`         |
| `Process.run_quiet cmd`  | `$(cmd)` (ignore result) |
| `Process.exit_code cmd`  | `$?(cmd).code`   |

`Process.pid` — the PID of the current wand process, not a spawned command —
has no equivalent in the new forms and moves to a top-level builtin `pid()` or
stays as a standalone `Process.pid` if the module is kept as a thin wrapper.
Decision: keep a minimal `Process` module with only `pid`.

## Lexer / parser changes

- Lex `$(` as a new token `DollarParen`; lex `$?(` as `DollarQueryParen`
- Parse `$(...)` and `$?(...)` as new expression nodes `ShellExpr of expr` and
  `ShellQuery of expr` where the inner `expr` is a string (literal or
  interpolated)
- In the pipeline desugaring pass (or evaluator), detect when a `ShellExpr` /
  `ShellQuery` is the right-hand side of a `|>` and wrap it in the stdin lambda

## Typechecker changes

- `ShellExpr`  → `TString`
- `ShellQuery` → record type `{ stdout: String, stderr: String, code: Int }`
  (requires named-field record support, which already exists via single-ctor
  type shorthand — may need an anonymous record type or a stdlib type alias
  `type ShellResult (stdout String, stderr String, code Int)`)

## Evaluator changes

- Add `process_run_stdin : string -> string -> string` builtin (cmd, stdin →
  stdout)
- `ShellExpr` standalone: call `process_run cmd`
- `ShellExpr` in pipeline: return closure over `process_run_stdin cmd`
- `ShellQuery` standalone: call `process_run_full cmd`
- `ShellQuery` in pipeline: return closure over `process_run_full_stdin cmd`

## README changes

- Remove `Process` module from stdlib listing
- Add a "Shell execution" section documenting `$()` and `$?()`
- Show pipeline composition examples
- Note that `Process.pid` remains for current-process introspection
