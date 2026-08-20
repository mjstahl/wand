(* The lint catalog: every rule's identity, classification, and wording.
   Nothing here inspects a program -- `Lint` does that and asks this module
   what to say -- so the full set of rules and the exact text a user sees can
   be reviewed on one screen.

   Rule IDs are a variant, not strings: a finding can only name a rule that
   exists, and adding a rule to the catalog without handling it is a
   compile error rather than a silent gap. The reference cites these same
   IDs, so prose and enforcement can be checked against each other. *)

type id =
  | V_PRED1    (* `?` names a predicate, so it must return Bool *)
  | V_OR1      (* an error that carries no information is a misfiled Option *)
  | V_NAME1    (* keyword-collision escapes should not reach a caller *)
  | V_PRED2    (* `?` already says predicate; `is_` says it twice *)
  | V_BANG1    (* it can raise, and the name does not say so *)
  | V_BANG2    (* the name says it raises, and it cannot *)
  | A_SHELL1   (* a shell blob hides work the type system could see *)
  | A_USES1    (* the manifest permits more than the file needs *)
  | A_USES2    (* the file reaches outside itself and does not say so *)
  | V_DROP1    (* a Result is thrown away, so nobody reads the failure *)
  | V_DROP2    (* an assertion's outcome is thrown away, so the test cannot fail *)
  | V_SHELL1   (* Shell is narrowed, but this command word is only known at run time *)
  | V_IMP1     (* an import binding is dead: a later import rebinds the name *)

(* The prefix says what a finding will do to you, so a rule ID printed in a
   terminal answers that on its own -- the same reason a raising function is
   spelled with a `!`.

   V- rules report a violation: something is wrong, and --strict promotes it
   to an error. A- rules are advisory and stay warnings however wand is run.

   Being decidable is what qualifies a rule to report a violation, but it
   does not oblige it: a rule can be perfectly decidable and still be
   advisory, because failing a build over it would punish the safer choice.
   Reclassifying a rule therefore renames it. *)
type kind =
  | Violation   (* --strict makes it an error *)
  | Advisory    (* always a warning *)

type rule = {
  id      : id;
  code    : string;
  summary : string;
  kind    : kind;
}

let all = [
  { id = V_PRED1;  code = "V-PRED1";
    summary = "a `?`-named function returns Bool";
    kind = Violation };
  { id = V_PRED2;  code = "V-PRED2";
    summary = "a `?`-named function also carries a redundant `is_` prefix";
    kind = Violation };
  { id = V_BANG1;  code = "V-BANG1";
    summary = "a function that can raise is not named with `!`";
    kind = Violation };
  { id = V_BANG2;  code = "V-BANG2";
    summary = "a `!`-named function cannot raise";
    kind = Violation };
  { id = V_OR1;    code = "V-OR1";
    summary = "an informationless error (`Result Unit _`) is a misfiled Option";
    kind = Violation };
  { id = V_NAME1;  code = "V-NAME1";
    summary = "a public signature exposes a trailing-underscore parameter";
    kind = Violation };
  { id = A_USES1;  code = "A-USES1";
    summary = "the manifest permits effects the file does not use";
    kind = Advisory };
  { id = A_USES2;  code = "A-USES2";
    summary = "the file performs effects and declares no manifest";
    kind = Advisory };
  { id = V_DROP1;  code = "V-DROP1";
    summary = "a statement discards a Result, so a failure goes unread";
    kind = Violation };
  (* A test block answers with one outcome, so an assertion before the last
     one is discarded and the test reports a pass however it went. The same
     shape as V-DROP1 and the same remedy shape, but its own rule: what is
     lost is the whole verdict, not the failure inside a value. *)
  { id = V_DROP2;  code = "V-DROP2";
    summary = "a statement discards an assertion, so the test cannot fail";
    kind = Violation };
  { id = V_IMP1;   code = "V-IMP1";
    summary = "an imported name is rebound by a later import before any use";
    kind = Violation };
  { id = A_SHELL1; code = "A-SHELL1";
    summary = "a large shell pipeline inside $() could be wand-level stages";
    kind = Advisory };
  (* A violation for its --strict semantics: a repo that narrows Shell can
     also insist every command word be readable from the text. *)
  { id = V_SHELL1; code = "V-SHELL1";
    summary = "the manifest narrows Shell, but this command word is decided at run time";
    kind = Violation };
]

let rule id = List.find (fun r -> r.id = id) all
let code id = (rule id).code
let kind id = (rule id).kind

let of_code c =
  match List.find_opt (fun r -> r.code = c) all with
  | Some r -> Some r.id
  | None   -> None

(* ── Messages ────────────────────────────────────────────────────────────── *)

(* Each message says what is wrong and what the author probably meant, in
   that order, without restating the rule ID the caller already prints. *)

let pred1 ~name ~actual =
  Printf.sprintf
    "'%s' is named as a predicate but returns %s; a `?` name promises Bool"
    name actual

let or1 ~name =
  Printf.sprintf
    "'%s' returns a Result whose error side is Unit, so a failure says only \
     that it happened; if there is no reason to report, this is an Option"
    name

let name1 ~name ~params =
  Printf.sprintf
    "'%s' exposes parameter%s named %s; a trailing underscore escapes a \
     keyword collision and is not part of the interface"
    name
    (if List.length params = 1 then "" else "s")
    (String.concat ", " (List.map (fun p -> "'" ^ p ^ "'") params))

let imp1 ~name ~first ~second ~line =
  Printf.sprintf
    "'%s' from %s is rebound by the %s import on line %d before anything \
     uses it; drop this import, or rename one binding ({%s = other_name})"
    name first second line name

let drop1 ~typ =
  Printf.sprintf
    "this statement's value is a %s and nothing reads it, so a failure here \
     is lost; match it, call the `!` sibling, or bind it to `_` to say the \
     failure does not matter"
    typ

let drop2 =
  "this statement is an assertion and nothing reads its outcome, so the test \
   passes however this assertion went; a test block answers with one outcome \
   -- return this one, or give each assertion its own `test` inside a `group` \
   so every one of them is reported"

let pred2 ~name =
  let bare = String.sub name 3 (String.length name - 3) in
  Printf.sprintf
    "'%s' says it is a predicate twice; `?` already carries that, so this is \
     '%s'" name bare

let bang1 ~name =
  Printf.sprintf
    "'%s' can raise, but its name does not say so; call it '%s!' and give the \
     plain name to a version that returns a Result" name name

let bang2 ~name =
  let bare = String.sub name 0 (String.length name - 1) in
  Printf.sprintf
    "'%s' cannot raise, so the `!` promises a risk that is not there; it is \
     '%s'" name bare

(* `corrected` is None when the file reaches outside itself for nothing:
   `uses {}` is not the advice there, since a file that does nothing outward
   has nothing to declare and the line should go. *)
let uses1 ~unused ~corrected =
  match corrected with
  | Some c ->
    Printf.sprintf
      "the manifest permits %s, which this file does not use; it could be \"%s\""
      unused c
  | None ->
    Printf.sprintf
      "the manifest permits %s, and this file reaches outside itself for \
       nothing; it could be removed"
      unused

(* Advisory rather than a violation, and deliberately so: a file without a
   manifest is legal, and a rule that failed a build over one would make
   every casual script pay for a feature it did not ask for. But a manifest
   is only worth having if it makes code better, so the linter is where the
   file is told what better looks like -- and it can hand over the exact
   line, since the effects are already inferred. *)
let uses2 ~performs ~corrected =
  Printf.sprintf
    "this file performs %s and does not say so; it could declare \"%s\""
    performs corrected

(* The same shape as uses1, for binaries instead of effect labels: the
   Shell(...) list admits a program no command position names. Only
   reported when every command position is literal -- an interpolated one
   may be exactly where the unused-looking binary is spawned. *)
let uses1_shell ~unused ~corrected =
  Printf.sprintf
    "the manifest allows %s, which no command here runs; it could be \"%s\""
    unused corrected

let shell1_dynamic =
  "this command's first word is decided at run time, so the Shell(...) \
   list is checked when it spawns rather than here"

let shell1 ~stages =
  Printf.sprintf
    "this $() is a %d-operator shell pipeline; stages moved into wand are \
     typed, and appear individually under --trace" stages
