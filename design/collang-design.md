# Collang: Design Summary

**Identity:** A scripting-first language for human-AI collaboration on shell-style tasks. ML-family syntax, modern type system, principled support for the kinds of work scripts actually do.

**Authoring model:** Duet assumes an AI assistant (Claude Code or similar) is the script author, with the human reviewing. Type complexity (long inferred effect rows, qualified types) is acceptable because the AI handles it during generation; the human reviews finished code where inferred types are usually invisible. The language is tuned for AI-writes, human-reviews, not for raw human authoring without tooling.

---

## Why Collang exists

### The collaboration story

Writing scripts together — human and AI — is one of the most common modes of programming collaboration today, and it's served by languages that weren't designed for it. Bash predates the collaborative use case entirely. Python is workable but lacks the type discipline to compress intent and catch slip-ups at the boundary. Modern typed scripting languages (TypeScript for Deno scripts, F# scripts) inherit features from application development that don't fit the scripting workflow.

Collang is designed for the specific shape of human-AI script collaboration:

**Intent compression through types.** When the AI generates a function, the type signature tells the human what the function does at a glance — what it takes, what it returns, what effects it performs. The human doesn't have to read the body to verify the contract; the contract is the type. Hindley-Milner inference means this benefit comes free of annotation burden.

**Examples as conversational artifacts.** When the AI demonstrates a function's behavior with a few input-output pairs in chat, those examples should live in the source, not in a transcript. Collang's first-class examples mechanism makes this transition seamless: the AI's demonstration becomes the language's verification. Six months later, the human reads the script and the examples are still there, still checked, still documenting.

**Effect honesty.** The AI cannot accidentally write a function that does IO without the signature reflecting it. The human, reviewing, can see at a glance what each function touches. No "did Claude remember to handle this side effect?" — the type system answers that. Effects are inferred, so the AI doesn't carry annotation burden; effects are surfaced, so the human can verify intent.

**Bug-catching at the slip-up level.** The bugs the AI most often produces in scripting aren't logical errors — they're details. Path-handling mistakes. Date format confusion. Unit slips. String-where-domain-value-was-meant. Collang's typed lexical literals catch these specifically. The AI is less likely to make them; the human is faster at spotting them when they happen.

**Sharpened iteration.** When the human pushes back ("this doesn't handle empty input"), the AI doesn't just patch the implementation — it adds an example that codifies the case, so the same bug can't return silently. The example is documentation, regression test, and intent record in one. The iteration produces durable artifacts, not just patches.

**Provenance for memory.** The AI doesn't carry memory across sessions; the human carries imperfect memory across months. Structured provenance metadata on bindings lets the script *remember* who suggested what and why. Future sessions — with the same human, with the same AI, or with neither — inherit context that would otherwise be lost.

The unifying principle: Collang externalizes the collaboration into the source artifact. What humans and AIs currently communicate through chat — types, examples, intent, rationale — Collang gives a place to live in the code itself. The conversation becomes a durable, checkable thing.

### The shell-scripting story

Shell scripts have a particular character: they manipulate domain values (paths, dates, durations, URLs, sizes), they orchestrate external processes, they live in pipelines, they get scheduled and survive for years past their creation, and they fail catastrophically when small details are wrong. The languages currently used for shell scripting were designed for other things — bash for interactive terminal use, Python for general application development, Perl for text processing. None of them treat shell scripting as a first-class concern.

Collang's features map to the specific shape of shell-script work:

**ML-family syntax — for clarity that survives the years.** Scripts outlive their creation. ML syntax is expression-oriented, structurally clear, and reads naturally even when its author has forgotten everything. Pattern matching makes case analysis legible. Pure functions don't carry incidental complexity. A script written in Collang at the moment of urgency is still readable when revisited at 3am during an incident two years later.

**Hindley-Milner inference — for ergonomics that match shell-script velocity.** Scripts get written quickly. Annotation ceremony slows that. HM inference means types are present (catching the bugs) but invisible (not slowing the writing). Types appear in the IDE for verification, in error messages for diagnosis, and at module boundaries for documentation — but inside a function, the code reads like a high-velocity scripting language.

**Pattern matching everywhere — for the structural manipulation scripts do constantly.** Scripts destructure CSV rows, parse log lines, route on command-line flags, dispatch on configuration shapes. Pattern matching with exhaustiveness checking makes this clear and correct. Guards let cases be precise. The argument-position destructuring means most script logic reads as direct manipulation of the data's shape.

**Lexical domain types — for the values scripts actually handle.** Scripts spend most of their effort on paths, dates, durations, URLs, IPs, sizes. Currently these are strings with conventions. In Collang they're typed values with literal syntax: `/var/log/app.log` is a path, `2024-01-15` is a date, `5min` is a duration, `192.168.1.0/24` is a CIDR block. The script reads like the domain it operates on. Type errors catch unit slips, format mismatches, and string-vs-path confusion before they become runtime bugs.

**Effects with handlers — for the testability scripts currently lack.** Shell scripts are notoriously hard to test because they're effectful. Algebraic effects with local handlers solve this: an example can run a script in a virtual filesystem with mocked time and canned process responses, asserting what the script *did*, not just what it returned. Testing isn't a separate framework — it's the effect system used in test mode.

**The `|>` pipeline operator — for the composition style shells made famous.** The shell's pipe is one of the most expressive ideas in computing. Collang's `|>` brings it inside the language, so script logic reads as a pipeline whether the elements are external processes or in-language transformations. Composition stays uniform.

**First-class process handling — for what shell scripts actually orchestrate.** Running external programs, capturing output, piping between processes, handling exit codes — these are first-class operations in Collang, not awkward library calls. The `$(...)` syntax for command substitution, the structured `run` function for explicit invocation, and the pipeline integration cover both quick scripting and robust orchestration.

**Single-binary deployment — for shipping scripts as artifacts.** Duet scripts run via the `duet` interpreter (`#!/usr/bin/env duet` shebang) or compile to a standalone native binary. No runtime to install, no virtual machine, no package dependencies. Scripts move like shell scripts: copy the file, run it. Scripts run with host permissions like any other shell script — no sandboxing.

**Sub-100ms startup — for scripts that have to feel like shell scripts.** If running a Collang script takes half a second to warm up, it loses to bash. The implementation strategy (interpretation or simple JIT initially, minimal runtime, lazy stdlib loading) is committed to making `collang script.col` feel as immediate as `bash script.sh`. Performance is a feature, not an optimization.

**Opinionated standard library — for the friction that compounds across scripts.** Scripts spend most of their imports on the same handful of operations: file walking, CSV reading, JSON parsing, regex matching, HTTP fetching, process invocation. Collang's standard library covers these canonically — one CSV library, one JSON library, one HTTP client — so the human and AI never spend collaboration time on "which library should we use." The opinion compresses the decision space.

The unifying principle: Collang treats shell scripting as a *first-class domain with first-class concerns*, not as a degraded form of application development. The language adapts to the work, rather than asking the work to adapt to it.

---

## Core language

- ML-family syntax — expression-oriented, `let`-bindings, pattern matching as first-class, lightweight function definition with `|` for multiple equations.
- Hindley-Milner inference extended with qualified types and row polymorphism (both records and effects).
- Algebraic data types with structural records.
- Pattern matching everywhere with exhaustiveness checking, including in argument position and with guards.
- `let` as the binding form everywhere — no separate `where` footnote syntax. (The `where` keyword is reserved for token pattern validation only.)
- `let*` sugar for sequencing within effects or monad-like types.
- `for ... in ... do ... end` sugar for `iter`, allowing imperative-style top-level script bodies.

## Dispatch (unified pattern-and-type)

- Pattern matching dispatches on any level of specificity from "any value" through "specific type" through "specific constructor" through "specific value." The compiler picks the most specific applicable clause.
- Implicit class generation — defining multiple clauses with different type signatures auto-creates the underlying type class. Explicit `class`/`instance` syntax remains available.
- Coherence enforced globally; explicit `orphan` annotations for exceptions.
- Open extensibility for cross-type dispatch; closed exhaustiveness for sum types.

## Effects

- Row-polymorphic effects in function signatures, inferred by default.
- Algebraic effects with handlers — effects are user-defined, handlers interpret them locally.
- Pure code stays visibly pure; effectful code shows effects in inferred types; explicit annotations at module boundaries.
- Script `start` gets default handlers for `<io>`, `<exn>`, `<exit>` so scripts don't need ceremony.

## Tokens (the REBOL-influenced move)

The lexer recognizes domain values at the token level. Each has a regex-defined validation pattern; invalid forms become sharp lexer errors at parse time. Operators on token types dispatch via the normal type-class system: `today() - 7d` yields a date a week ago; `log_dir / "filename"` joins paths. Whitespace is required around operators to disambiguate from token internals.

**Base token types:**

- `Path` — `/etc/foo`, `./script`, `~/projects`, `../sibling`
- `Date` — `2024-01-15`
- `Time` — `14:32:01`
- `DateTime` — `2024-01-15T14:32:01Z`
- `Duration` — `5min`, `1h30m`, `2d`
- `URL` — `https://example.com/path`
- `IPv4` — `192.168.1.1`
- `IPv6` — `::1`, `fe80::1`
- `CIDR` — `192.168.0.0/24`
- `Port` — `:8080`
- `Version` — `1.2.3`, `1.2.3-alpha.1`
- `Size` — `1.5GB`, `10MB`, `512KB`

Path syntax follows shell conventions: no delimiters needed for shapes starting with `/`, `./`, `../`, or `~`. Explicit `path "..."` for ambiguous cases (bare relative paths).

Money and other domain-specific types are handled by user-defined tokens (below), not by the base language.

## User-defined tokens

Users can extend the lexer with new typed literals via `token` declarations. This is what enables domain-specific scripting (finance, networking, scientific units, bioinformatics) without forking the language.

A `token` declaration has three clauses: `pattern` (regex with optional validation), `value` (how to construct the typed value from regex captures), and `show` (how to print it back). It attaches to an existing type:

```duet
type IPv4 = IPv4 { a : Int, b : Int, c : Int, d : Int }

token IPv4 where
  pattern = /(\d+)\.(\d+)\.(\d+)\.(\d+)/
    where a = int $1, b = int $2, c = int $3, d = int $4,
          a <= 255 && b <= 255 && c <= 255 && d <= 255
  value = IPv4 { a, b, c, d }
  show ip = "${ip.a}.${ip.b}.${ip.c}.${ip.d}"
```

**Rules:**

- **`pattern`** is a regex; positional captures bind as `$1`, `$2`, etc. An optional `where` clause names the captures and adds validation predicates. Validation failure produces a lex-time error at the literal's location.
- **`value`** constructs the typed value from the captured bindings. Must be pure (no `<io>` effect); the compiler rejects effectful `value` clauses.
- **`show`** is the inverse of `value`. Auto-derives `instance Show` for the type.
- **Parse-time for literals, runtime for `Type.parse`.** A literal in source code (`192.168.1.1`) runs `value` during the lex/parse phase before the script starts executing; the constructed value is embedded in the AST. A dynamic string (`IPv4.parse user_input`) runs `value` at runtime and returns a `Result`. Both modes use identical code — they differ only in when they execute.
- **Tokens come in via normal `import`.** Importing a module brings in its functions, types, and tokens together. The compiler loads tokens during the lex pass before parsing.
- **Conflict-checked at registration time.** If a new token's pattern ambiguously overlaps with built-in tokens or other loaded tokens, the compiler reports it immediately, not at use time.
- **Each token must have a recognizable shape** — unique starting character, prefix, or structural pattern — so the cognitive load of "what could this token be?" stays bounded.

## Module system (lightweight)

Scripting languages don't need a sophisticated module system. Collang takes the lightweight approach:

- **Files are modules implicitly.** Each `.duet` file is a module. Filename matches module name, capitalized (e.g. `List.duet` is module `List`).
- **Module names are capitalized; values are lowercase.** Compiler-enforced at the lexer level. `List.map` is unambiguously `List` (module) dot `map` (function); `list.map` is `list` (value) dot `map` (field). Same disambiguation as OCaml, Haskell, and Elixir.
- **Bare names import from the standard library or installed packages.** `import List` resolves `List` from the standard library; `import Http.Client` resolves an installed third-party package.
- **Path-prefixed imports resolve to local files.** `import ./Utils` imports `Utils.duet` from the current directory; `import ../shared/Network/CIDR` walks the filesystem. The leading `./` or `../` is the signal — same convention as shells.
- **Third-party packages live where the package manager puts them** (e.g. `~/.duet/packages/`), imported by bare name. The package manager handles download and naming.
- **Local files shadowing standard library modules produce a compiler warning.** If you create `./List.duet`, `import List` still resolves to the standard library; importing the local version requires `./List`. The warning tells you which one you got.
- **Type class coherence via orphan annotations.** Instances defined outside the module that owns the class or type require an explicit `orphan` marker. Conflicting orphan instances are detected at import time, not at use time.
- **Underscore prefix means private.** Names like `_helper` are module-private; the compiler refuses to resolve them from outside the defining module.
- **Type inference handles export types.** The inferred type of each public name is what importers see. No signatures needed.
- **Imports are static.** Must appear at the top of the file, never inside functions or conditionals.
- **Hierarchical organization via directory structure.** `Network/CIDR.duet` is module `Network.CIDR`. The filesystem path *is* the namespace path.

What this *doesn't* have, intentionally: abstract types across module boundaries, parametric modules (functors), explicit signatures, multiple implementations of the same interface. These features matter for large-scale software engineering; they don't matter for scripting. They can be added later as focused features (abstract types in particular) if Collang grows beyond scripting. Retrofitting permissiveness onto a strict system is harder than adding discipline to a permissive one.

## Collaboration features

- **Doc comments** — `(* *)` comments immediately preceding a definition are picked up as documentation. Content is markdown by convention. First line is the summary; rest is detail. Tooling (LSP hover, `duet doc <name>`, doc generators) reads from the same place.
- **Embedded examples** — examples live inside doc comments using shell-flavored prefixes: `$` for input, `=` for return value, `#` for state/effect assertions (e.g. `# wrote /path = "..."`, `# printed "text"`, `# exited 1`). The tooling extracts these and runs them in check mode. Multi-line examples use markdown fenced code blocks. This is the *only* example mechanism — there is no separate standalone `examples` block.
- **Holes** — first-class `?` placeholders with type-driven completion.
- **Contracts** — `requires` and `ensures` clauses on function definitions. Runtime-checked by default; `--no-contracts` flag disables for production runs. `result` is reserved inside `ensures` only, referring to the function's return value. Contract failures raise the `<exn>` effect with location, predicate, and offending values.

  ```duet
  let factorial n
    requires n >= 0
    ensures result >= 1
    = match n with
      | 0 -> 1
      | _ -> n * factorial (n - 1)

  let parse_port s
    ensures result >= 0 && result <= 65535
    = ...
  ```

## AI authoring guide

No LLM will be trained on Duet — the language is too new and too small to appear in training corpora. To make AI assistants effective from day one, Duet ships with a `STYLE.md` (or equivalent) that AI assistants ingest as context before generating Duet code. Without it, AI assistants would generate plausible-looking code that misses Duet-specific idioms and conventions.

The guide covers:

- **Idiomatic patterns** — when to use tokens vs raw strings, how to structure script entry (`start`), where effect handlers go.
- **Doc comment conventions** — what goes in summary vs detail, when to include examples, how to write `requires`/`ensures` clauses, the `$`/`=`/`#` example syntax.
- **Effect handling patterns** — when to handle effects locally vs propagate, default handlers at `start`, the purity rule for token clauses.
- **Module organization** — capitalized names, file-as-module, when to split files, path-based vs bare-name imports.
- **Common AI pitfalls** — patterns AI tends to over-apply (parallel mechanisms when one would do, elaborate type annotations, separate examples blocks, generic exception handling). The catch-up brief's meta-pattern (additive vs subtractive design) lives here.
- **Worked examples** — short scripts demonstrating each pattern, written as the canonical reference for AI assistants generating similar code.

The guide is part of the language's distribution, versioned alongside the compiler. Updates to the language come with updates to the guide. AI assistants working on Duet are expected to read it; humans reviewing AI-generated Duet code can read it to understand what the AI was aiming at.

## Target story

- Native compilation via OCaml's `ocamlopt`. Standalone binary, no runtime to install, sub-100ms startup.

## Standard library philosophy

- Opinionated and batteries-included for scripting essentials.
- Single canonical option for common needs (one string type, one JSON library, one CSV parser, one HTTP client).
- Rich domain operations on lexical types (path manipulation, date arithmetic, duration arithmetic, etc.).

## MVP scope

Six phases — walking skeleton, scripting essentials, effects, classes and dispatch, collaboration features, polish — each producing a usable artifact, totaling a coherent scripting language for human-AI collaboration.

## The animating principle

A language designed for the *pair* — human and AI collaborating on real work. Types compress intent. Doc comments with embedded examples bridge conversation and source — reasoning, demonstrated behavior, and documentation share a single durable home. Lexical domain types let the syntax match the work. Effects make signatures honest. Pattern matching unifies dispatch across all levels of specificity. The collaboration features make the language a partner in the work, not just a medium for it.
