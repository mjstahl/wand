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
  { id = A_SHELL1; code = "A-SHELL1";
    summary = "a large shell pipeline inside $() could be wand-level stages";
    kind = Advisory };
]

let rule id = List.find (fun r -> r.id = id) all
let code id = (rule id).code
let kind id = (rule id).kind

let of_code c =
  match List.find_opt (fun r -> r.code = c) all with
  | Some r -> Some r.id
  | None   -> None

let kind_name = function
  | Violation  -> "violation"
  | Advisory -> "advisory"

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

let shell1 ~stages =
  Printf.sprintf
    "this $() is a %d-operator shell pipeline; stages moved into wand are \
     typed, and appear individually under --trace" stages
