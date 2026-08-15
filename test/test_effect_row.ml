open Wand
open Effect_row

let shows label r expected =
  Alcotest.(check string) label expected (string_of_row r)

let unifies label a b =
  try unify a b with
  | RowError m -> Alcotest.failf "%s: expected these to unify, got: %s" label m

let conflicts label a b =
  match unify a b with
  | () -> Alcotest.failf "%s: expected a conflict, but they unified" label
  | exception RowError _ -> ()

(* ── Display ─────────────────────────────────────────────────────────────── *)

(* Labels print in a fixed order rather than alphabetically, so two
   signatures can be compared by eye. *)
let test_display () =
  shows "empty" pure "{}";
  shows "one" (single Shell) "{Shell}";
  shows "several, in lattice order"
    (of_list [Raise; FsRead; Shell]) "{Shell, FS.Read, Raise}";
  shows "unknown" (fresh_row ()) "{..}";
  shows "known plus unknown"
    (add Shell (fresh_row ())) "{Shell | ..}"

(* ── Closed rows ─────────────────────────────────────────────────────────── *)

let test_closed_rows () =
  unifies "identical" (of_list [Shell; Raise]) (of_list [Raise; Shell]);
  unifies "both empty" pure pure;
  conflicts "different labels" (single Shell) (single Proc);
  conflicts "one has more" (of_list [Shell; Raise]) (single Shell);
  (* A closed row cannot grow, so a pure function is not silently accepted
     where an effectful one is required. *)
  conflicts "pure against effectful" pure (single Shell)

(* ── Open against closed ─────────────────────────────────────────────────── *)

let test_open_takes_on_closed () =
  let r = fresh_row () in
  unifies "unknown row learns the effects" r (of_list [Shell; FsRead]);
  shows "and is now exactly those" r "{Shell, FS.Read}";
  Alcotest.(check bool) "closed afterwards" true (is_closed r);
  (* The open side keeps what it already knew. *)
  let r2 = add Raise (fresh_row ()) in
  unifies "open with a known label" r2 (of_list [Raise; Shell]);
  shows "gains only what was missing" r2 "{Shell, Raise}";
  (* But it cannot claim something the closed side lacks. *)
  let r3 = add Proc (fresh_row ()) in
  conflicts "open claims an effect the closed side lacks" r3 (single Shell)

(* ── Open against open ───────────────────────────────────────────────────── *)

(* Two unknown rows must stay linked: learning about one has to reach the
   other, or a function's effects and its caller's drift apart. *)
let test_open_rows_link () =
  let a = fresh_row () and b = fresh_row () in
  unifies "two unknowns" a b;
  unifies "then one learns something" a (of_list [Shell]);
  shows "the first" a "{Shell}";
  shows "and the second followed" b "{Shell}"

let test_open_rows_merge_known_labels () =
  let a = add Shell (fresh_row ()) in
  let b = add FsRead (fresh_row ()) in
  unifies "each knows a different effect" a b;
  shows "first sees both" a "{Shell, FS.Read | ..}";
  shows "second sees both" b "{Shell, FS.Read | ..}"

(* The case inference leans on hardest: two rows are linked while both are
   still unknown, and the facts arrive afterwards. Whatever either learns
   later has to reach the other. *)
let test_information_arrives_after_linking () =
  let a = add Shell (fresh_row ()) in
  let b = add FsRead (fresh_row ()) in
  unifies "link two partly-known rows" a b;
  unifies "then close one of them" a (of_list [Shell; FsRead]);
  shows "the closed one" a "{Shell, FS.Read}";
  shows "and the other followed" b "{Shell, FS.Read}";
  Alcotest.(check bool) "both are closed now" true (is_closed b)

let test_three_rows_in_a_chain () =
  let a = fresh_row () and b = fresh_row () and c = fresh_row () in
  unifies "a with b" a b;
  unifies "b with c" b c;
  unifies "and c learns" c (single Proc);
  shows "a" a "{Proc}";
  shows "b" b "{Proc}";
  shows "c" c "{Proc}"

let test_unifying_a_row_with_itself () =
  let r = add Shell (fresh_row ()) in
  unifies "a row with itself" r r;
  shows "unchanged" r "{Shell | ..}"

(* One variable on both sides carrying different labels is a recursive
   equation, `p = {IO} + p`, not a conflict -- it is the shape a function
   that calls itself produces. Solving it binds the variable to what the two
   sides disagree on, after which both read the same. *)
let test_same_variable_different_labels () =
  let v = fresh_rowvar () in
  let ambient = Row (EffSet.singleton IO, Some v) in
  let recursive_call = Row (EffSet.empty, Some v) in
  unifies "the recursive equation is solved" ambient recursive_call;
  shows "the effect survives on both sides" ambient "{IO | ..}";
  shows "and the other side now carries it too" recursive_call "{IO | ..}"

let test_same_variable_disjoint_labels () =
  let v = fresh_rowvar () in
  let a = Row (EffSet.singleton IO, Some v) in
  let b = Row (EffSet.singleton Shell, Some v) in
  unifies "two effects, one variable" a b;
  shows "both sides carry both" a "{Shell, IO | ..}";
  shows "on the other side as well" b "{Shell, IO | ..}"

(* ── Occurs check ────────────────────────────────────────────────────────── *)

(* Binding a variable to a row that contains it would build a row standing
   for itself, which no amount of unfolding resolves. *)
let test_occurs_check () =
  let v = fresh_rowvar () in
  let r = Row (EffSet.singleton Shell, Some v) in
  match bind v r with
  | () -> Alcotest.fail "expected the occurs check to reject a self-referential row"
  | exception RowError _ -> ()

(* ── Building rows ───────────────────────────────────────────────────────── *)

let test_add_remove_union () =
  shows "add" (add Shell pure) "{Shell}";
  shows "add is idempotent" (add Shell (single Shell)) "{Shell}";
  shows "remove" (remove Shell (of_list [Shell; Raise])) "{Raise}";
  shows "remove what is absent" (remove Proc (single Shell)) "{Shell}";
  shows "union" (union (single Shell) (single FsRead)) "{Shell, FS.Read}";
  shows "union with pure" (union (single Shell) pure) "{Shell}";
  (* Union keeps the row open if either side is. *)
  shows "union stays open" (union (single Shell) (fresh_row ())) "{Shell | ..}"

let test_membership () =
  Alcotest.(check bool) "present" true (mem Shell (of_list [Shell; Raise]));
  Alcotest.(check bool) "absent" false (mem Proc (of_list [Shell; Raise]));
  Alcotest.(check bool) "nothing is in a pure row" false (mem Shell pure)

(* ── Free variables ──────────────────────────────────────────────────────── *)

(* Schemes quantify row variables, so they have to be findable, and a row
   that has been resolved must report none. *)
let test_free_rowvars () =
  Alcotest.(check int) "closed row has none" 0 (List.length (free_rowvars pure));
  let r = fresh_row () in
  Alcotest.(check int) "open row has one" 1 (List.length (free_rowvars r));
  unifies "once resolved" r (single Shell);
  Alcotest.(check int) "it has none" 0 (List.length (free_rowvars r))

let () =
  Alcotest.run "EffectRow" [
    "display", [
      Alcotest.test_case "rendering" `Quick test_display;
    ];
    "unification", [
      Alcotest.test_case "closed"            `Quick test_closed_rows;
      Alcotest.test_case "open takes closed" `Quick test_open_takes_on_closed;
      Alcotest.test_case "open rows link"    `Quick test_open_rows_link;
      Alcotest.test_case "open rows merge"   `Quick test_open_rows_merge_known_labels;
      Alcotest.test_case "late information"  `Quick test_information_arrives_after_linking;
      Alcotest.test_case "chain of three"    `Quick test_three_rows_in_a_chain;
      Alcotest.test_case "self-unification"  `Quick test_unifying_a_row_with_itself;
      Alcotest.test_case "recursive equation" `Quick test_same_variable_different_labels;
      Alcotest.test_case "disjoint, one var"  `Quick test_same_variable_disjoint_labels;
      Alcotest.test_case "occurs check"      `Quick test_occurs_check;
    ];
    "construction", [
      Alcotest.test_case "add/remove/union" `Quick test_add_remove_union;
      Alcotest.test_case "membership"       `Quick test_membership;
      Alcotest.test_case "free row vars"    `Quick test_free_rowvars;
    ];
  ]
