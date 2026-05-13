# Collang/Duet: Catch-Up Brief

A briefing document for a Claude joining the design conversation. Read alongside the design document (currently `collang-design.md`), which contains the consolidated design.

**Name status:** The language was initially called "Collang." The user expressed dissatisfaction with that name and showed interest in "Duet" but never explicitly committed. The design doc and this brief still use "Collang" in titles and the file extension `.duet` is used in code examples. The catch-up brief and design doc are inconsistent on this point. *Ask the user before renaming.*

---

## What this is

The user (a thoughtful programmer with strong language-design intuitions) and Claude have been collaboratively designing a scripting language called **Collang** (possibly to be renamed Duet). The design document captures where the conversation landed. This brief captures the *context around* the design — the path that got there, the user's priorities, and the working dynamic — so a future Claude can pick up the conversation rather than start cold.

If the user references the language and you have no other context, read the design document first. Then read this. Then you should be roughly caught up.

---

## How the conversation unfolded

The conversation didn't start with "design a language." It started with the user asking about Claude's familiarity with Ada, then progressed through a series of questions that gradually narrowed onto language design:

1. *Calibration questions.* What programming qualities are easiest for Claude to write? Type systems? Syntax preferences? Multiple dispatch and destructuring? These weren't idle — they were the user mapping Claude's preferences before asking what Claude would actually want.

2. *The pivot to design.* "If I was designing a language for you, an LLM, would you want more guarantees or more openness?" This is where the conversation became collaborative design rather than Q&A. Claude's answer (guarantees in the local, openness at the seams) framed the priorities.

3. *Feature exploration.* The user pulled on specific threads: small surface vs. deep core, light effects, the combination of ML syntax + HM + destructuring + multiple dispatch. Each thread converged with the others into a coherent design.

4. *The unification moment.* The user pointed out that dispatching on type vs. dispatching on structure are points on the same specificity lattice, not different mechanisms. This reframed a chunk of the design — pattern matching and multiple dispatch aren't separate features, they're a unified dispatch mechanism with implementation strategies that differ by where on the lattice the pattern sits. This is one of the design's most important moves and it came from the user, not Claude.

5. *The scoping move.* "What if we wrote to be a scripting language first?" This anchored everything that had been abstract into a concrete domain. Suddenly the features had a use case to justify them, and the scope became tractable. Collaboration features in particular went from "nice ideas" to "obviously valuable for this use case."

6. *The REBOL influence.* The user proposed that script-domain types (dates, paths, URLs) be lexical, not constructed. This was the move that gave Collang its distinct character — it stopped being "ML with collaboration features for scripting" and became something more particular: a language where the lexer recognizes the shapes scripts actually handle. The user's instinct here was sharp and right.

7. *The extension question.* From lexical types built into the language, the user pushed to user-extensible lexical types. Claude agreed (with appropriate hedging) and proposed governance constraints. This stays Phase 2 — committed in direction, deferred in implementation.

8. *The backtick correction.* Late in the conversation, the user asked whether backticks (which Claude had agreed to for path literals) were really the right choice. Claude re-examined and concluded no — paths should follow shell conventions, recognized lexically without delimiters. This is worth noting: the user *invited* the re-examination, and Claude needed it. The user is generally better than Claude at spotting when Claude has agreed too quickly.

The animating principle that emerged: **a language for the human-AI pair, where the source artifact externalizes what humans and AIs currently communicate through chat.** Types, examples, intent, rationale — all get places to live in the code itself.

---

## What the user seems to value

Reading this from outside the conversation, the user's priorities aren't always explicit in the design doc. Some inferred:

**Genuine collaboration over performative agreement.** The user pushes back when Claude agrees too quickly. The user asks "is X really the right way?" specifically to invite re-examination, not to receive confirmation. When you find yourself agreeing to something quickly, you should probably re-examine it before continuing.

**Concrete over abstract.** The user repeatedly pulled the conversation toward concreteness — concrete syntax examples, concrete scripting tasks, concrete tradeoffs. When the conversation got abstract, the user grounded it. Expect this and lean into concreteness proactively.

**Domain fit over universal elegance.** The REBOL move and the scripting-first scoping both reflect a preference for languages that fit their domain over languages that are elegant in the abstract. Collang isn't trying to be a beautiful general-purpose language; it's trying to be a *useful* scripting language with strong type discipline. Keep that orientation when discussing tradeoffs.

**Power with discipline.** The user proposed user-extensible lexical types — a powerful feature. Claude's instinct to add governance constraints (scoping, conflict detection, layered ecosystem) was received well. The user isn't looking for "as much power as possible" but for "real power with sensible constraints." Apply the same template to other extensibility questions.

**Iteration over up-front design.** The MVP roadmap (six phases) and the deferral of user-extensible lexical types to Phase 2 reflect a willingness to ship something tight and grow. Don't try to design everything at once.

---

## Decisions made (in addition to the design doc)

These came up during the conversation and got settled. They're noted here for context, but the design doc has the authoritative current state.

**Resource management.** Settled: `with` blocks for scoped resources (`with file = open path in <body>`). Files auto-close on scope exit. No linear types — simpler is right for scripting.

**Ambiguity resolution for dispatch.** Settled: compile error when two clauses are equally specific. User adds a more specific clause to disambiguate.

**Whitespace-around-operators rules.** Settled: linter normalizes; if it can't, compiler errors. Edge cases handled at implementation time.

**The exact form of contracts.** Settled: `requires` / `ensures` clauses on function definitions, runtime-checked by default, `--no-contracts` flag disables. `result` is reserved inside `ensures` referring to the return value. Contract failures raise `<exn>`.

**The exact form of examples.** Settled: embedded in doc comments using `$` (input), `=` (return), `#` (state/effect assertion). Markdown fenced blocks for multi-line. No separate examples mechanism.

**Provenance metadata format.** Settled: dropped. Doc comments handle the use case. No separate provenance mechanism.

**Concurrency model.** Settled: dropped. Scripts compose via OS processes and pipes — same as any shell-driven workflow.

**Distribution and sandboxing.** Settled: shebang + interpreter OR compile to per-platform native binary. Scripts run with host permissions, no sandboxing — like bash.

**Wasm target.** Settled: dropped. Native compilation via OCaml's `ocamlopt` is the only target.

**Implementation language.** Settled: OCaml. ML-family host language for an ML-family target is the natural fit; OCaml 5's algebraic effects make implementing Duet's effects straightforward.

**Module system.** Settled: lightweight. Files-as-modules, capitalized names, path-based imports for local files (`import ./Utils`), bare-name imports for stdlib/packages (`import List`), underscore prefix means private, compiler warning on stdlib shadowing.

**Token system.** Settled: `token` keyword (not `lexical`), three clauses (`pattern`, `value`, `show`), regex captures bind as `$1`/`$2`/etc., `where` clause for validation. Auto-derives `Show` instance. Pure functions only in `value` and `where`. Parse-time for literals, runtime for `Type.parse`. Unified with `import` — no separate `use token` keyword.

**Base token types.** Settled: `Path`, `Date`, `Time`, `DateTime`, `Duration`, `URL`, `IPv4`, `IPv6`, `CIDR`, `Port`, `Version`, `Size`. Money and others handled via user-defined tokens.

**Orphan instance conflicts.** Settled: detected at import time, not use time. Error reports the conflicting modules and suggests resolution (drop an import or define a non-orphan shadowing instance).

**Property tests.** Settled: dropped from MVP. Examples cover the common case.

**Script entry point.** Settled: `start`, not `main`. Verb fits action-oriented scripts; `main` is C inheritance.

---

## Things explicitly considered and rejected

Important to remember, because a fresh Claude might re-propose them without realizing they were discussed and dropped:

**Wasm as a deployment target.** Initially proposed by Claude for sandboxing and universal deployment. Re-examined and dropped. Native compilation via OCaml's `ocamlopt` is the only target; scripts run via shebang + interpreter or compiled binary, with host permissions like bash.

**Property-based testing.** Initially proposed as a collaboration feature. Re-examined and dropped from MVP. Examples cover the common case; properties were additive complexity that scripts mostly don't need.

**`where` as a let-footnote affordance.** Initially proposed for the "footnote" style of bindings attached to function definitions. Removed to free the keyword for token validation only. `let` is the only binding form now.

**`main` as the script entry point.** Replaced with `start`. Verb fits action-oriented scripts; `main` is C inheritance with no special claim on the role.

**`lexical type` as the declaration syntax.** Replaced with `token`. More concrete, less jargon, reads naturally in both declaration and usage.

**Separate `use lexical` import.** Replaced with unified `import`. Importing a module brings in its functions, types, and tokens together — no separate keyword needed.

**Structured provenance as a separate mechanism.** Initially proposed as "metadata on bindings (author, intent, history) for human-AI traceability." Re-examined when the user asked for a concrete example. Replaced by doc comments (markdown convention, `(* *)` immediately preceding a definition). Reasoning that would otherwise be lost in chat goes into the doc comment alongside the code. One mechanism for documentation + intent + rationale, not three.

**A separate `examples` block alongside doc comments.** Initially carried as a parallel mechanism for "complex examples that don't fit in prose." Re-examined when the user asked "do we need both?" Replaced by embedded examples inside doc comments using shell-flavored prefixes: `$` for input, `=` for return, `#` for state/effect assertions. Markdown fenced blocks handle multi-line cases. One mechanism for examples, not two.

**ML-style structures and signatures (functor-based module system).** Initially proposed by Claude. Re-examined when the user asked "do we need a module system or can we just import scripts?" Replaced with a lightweight model: files are modules, underscore-prefix means private, type inference handles export types, no signatures or functors. The lightweight model is appropriate for scripting; the ML-style system was overspecified for the use case. If Duet grows beyond scripting, abstract types and richer abstraction can be added as focused features later.

**Backticks for path literals.** Initially proposed, agreed to, then re-examined and dropped. Paths now follow shell conventions: `/etc/foo`, `./script`, `../sibling`, `~/projects` are recognized lexically without delimiters. Explicit `path "..."` for ambiguous cases (bare relative paths like `scripts/build.sh`). If you find yourself thinking "let's use some delimiter for paths," remember: this was considered and discarded.

**Implicit conversion from string literals to paths.** Considered as an alternative to backticks. Rejected because it makes string literals subtly polymorphic and degrades error messages. The lexical-types approach is better.

**Separate mechanisms for pattern matching and multiple dispatch.** Claude initially treated these as different features that should coexist. The user pointed out they're points on the same specificity lattice. The unified view is now committed; don't revert to the split view.

**Heavy effect tracking (Haskell-style monadic IO).** Considered as the standard approach. Rejected because it makes pure-to-effectful refactoring expensive and adds syntactic ceremony. Row-polymorphic effects with handlers, inferred by default, was the chosen approach.

**Required type annotations everywhere.** Considered (in the spirit of "annotations help Claude reason"). Rejected because HM inference is the right default; annotations should be optional but visible (IDE shows inferred types).

**Functors as a separate module-parameterization mechanism.** Considered (ML-style). Rejected because type classes / implicit class generation can do the same job more uniformly.

**REBOL-style permissive lexing (accept malformed dates, validate later).** Considered. Rejected in favor of regex-based lex-time validation with sharp errors. The user's question about regex validation was the trigger for this refinement.

---

## The working dynamic

Some observations about how the user and Claude work together that might be useful:

**Claude tends to propose additive solutions; the user proposes subtractive ones; subtractive usually wins.** This pattern has repeated multiple times: structured provenance → just doc comments; ML-style modules → just import scripts; separate examples block → just embedded examples in doc comments. When the user asks "do we need X" or "what if Y could do this work," that's an invitation to drop a parallel mechanism, not to defend it. Future Claudes should treat such questions as opportunities to simplify, and should proactively ask "is this a new mechanism or can an existing one cover it?" before proposing additive features.

**The user asks short, sharp questions.** "Is X the right way?" "What about Y?" "Does Z matter?" These are invitations to think, not requests for confirmation. Take them seriously — the user has usually noticed something.

**The user values terse responses.** Long exploratory answers are tolerated for genuinely complex design questions, but the user has explicitly asked for shorter responses. Default to concise; expand only when the question warrants it.

**Claude tends to be verbose; the user is patient with this.** Long Claude responses with explored tradeoffs are welcomed for genuinely hard design questions. But the user does push for concreteness eventually and has explicitly asked for terseness. Mix exploration with commitment; prefer brief when possible.

**The user notices when Claude is hedging vs. when Claude has a real opinion.** When Claude expresses honest preference ("I'd want this because..."), the user engages with it. When Claude hedges performatively, the user pushes through. Lean toward expressing real preference, with reasoning.

**Honesty about uncertainty is valued.** When Claude says "I'm not sure about this" or "I'd want to re-examine," the user takes it as useful information, not as weakness. Don't over-claim certainty.

**The user is comfortable with deferral.** "We'll figure that out later" is acceptable for genuine open questions. But explicit deferral is better than implicit hand-waving.

**The user thinks across domains.** REBOL, SQL, dependently-typed languages, Julia, OCaml, Rust, bash, Lisp — the user moves between these without ceremony. Don't assume the user only knows mainstream languages.

**The authoring environment is Claude Code (or equivalent).** The language is designed for AI to write and humans to review, not for raw human authoring. Type complexity (long inferred effect rows, qualified types) is acceptable because the AI mediates the writing experience. The AI authoring guide (`STYLE.md` in the design doc) is the mechanism for making this work, since no LLM will be trained on the language.

---

## Where the conversation could go next

A few productive directions, in case you're picking up mid-conversation:

**Write the AI authoring guide (`STYLE.md`).** The design doc commits to this artifact but the artifact itself doesn't exist yet. It's the most natural next deliverable: idiomatic patterns, doc comment conventions, effect handling patterns, common AI pitfalls, worked examples. This is where Duet becomes usable for AI assistants.

**Write more example scripts.** The three scripting examples earlier in the conversation (log analysis, file renaming, CSV processing) surfaced design issues abstract discussion missed. More realistic scripts would do the same. Suggestions: a deployment script, a backup script, a data-pipeline script, a system-monitoring script.

**Stress-test the design.** Pick something hard to do in current languages and see if Duet would help. Examples: orchestrating multiple cloud services with retries, a build script with dependency graphs, a security audit script.

**Start the implementation.** The design is settled enough to begin a walking-skeleton interpreter in OCaml. Phase 1 of the MVP roadmap.

**Compare to existing languages.** Take a specific script written in bash or Python, rewrite it in Duet, and see what's better, worse, or just different. Grounds the design in real comparisons.

**Address skepticism.** Pick parts of the design you're least confident about and try to break them. The user is good at this; you can be too.

---

## A note on continuity

The conversation has a particular character — exploratory, iterative, willing to revise. If you pick it up, try to match that character. Don't treat the design doc as fixed; treat it as a snapshot of where we are. The user will tell you what's open vs. settled. When in doubt, ask.

The design is largely settled but new questions will arise as implementation begins or as scripts get written. Honor the user's time by continuing to think carefully, not by performing certainty about things that are actually still in flight.

Good luck.
