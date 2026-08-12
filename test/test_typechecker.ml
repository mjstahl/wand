open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

let err_contains label input needle =
  let contains haystack needle =
    let hn = String.length haystack and nn = String.length needle in
    if nn = 0 then true
    else if nn > hn then false
    else begin
      let found = ref false in
      for i = 0 to hn - nn do
        if String.sub haystack i nn = needle then found := true
      done;
      !found
    end
  in
  match run input with
  | Error msg ->
    if not (contains msg needle) then
      Alcotest.failf "%s: expected '%s' in error, got: %s" label needle msg
  | Ok s -> Alcotest.failf "%s: expected error but got: %s" label s

(* ── Dot access is checked field access ──────────────────────────────────── *)

(* `p.x` on a named type is verified against the type's fields. Key presence
   in a Map is a runtime question, so dot access on a Map is rejected and
   lookup goes through Map.get / Map.get! instead. *)

let test_map_dot_access_rejected () =
  err_contains "dot access on a Map"
    "let m = [x = 1, y = 2] in m.x"
    "cannot use dot access on a Map"

let test_named_field_access_checked () =
  ok "field access on a named type resolves"
    {|type P = P(x: Int, y: Int)
let p = P(x = 1, y = 2) in p.x|}
    "1";
  err_contains "unknown field on a named type"
    {|type P = P(x: Int, y: Int)
let p = P(x = 1, y = 2) in p.z|}
    "has no field 'z'"

let test_map_patterns_still_work () =
  ok "map pattern binds a key"
    {|let m = [x = 1, y = 2] in
match m with
| [x = a] -> a|}
    "1"

(* ── Named-field types are built and matched by name ─────────────────────── *)

(* Positional forms on a named-field type reorder silently when two fields
   share a type, so they are rejected. Constructors without named fields are
   positional by nature and unaffected. *)

let point = {|type P = P(x: Int, y: Int)|}

let test_positional_construction_rejected () =
  err_contains "positional construction of a named-field type"
    (point ^ "\nlet p = P (1, 2) in p.x")
    "has named fields"

let test_tuple_destructuring_rejected () =
  err_contains "tuple destructuring of a named-field type"
    (point ^ "\nlet p = P(x = 1, y = 2) in\nlet (a, b) = p in a + b")
    "cannot destructure 'P' with tuple syntax";
  err_contains "single-field paren destructuring"
    {|type C = C(r: Int)
let c = C(r = 7) in
let (v) = c in v|}
    "cannot destructure 'C' with tuple syntax"

let test_named_forms_survive () =
  ok "named construction and named pattern"
    (point ^ "\nmatch P(x = 1, y = 2) with | P(x = a, y = b) -> a + b")
    "3"

let test_positional_constructors_unaffected () =
  ok "constructor without named fields stays positional"
    {|type Shape = Circle Float | Square Float
match Circle 3.0 with | Circle r -> r | Square s -> s|}
    "3";
  ok "tuple destructuring of an actual tuple"
    "let (a, b) = (1, 2) in a + b"
    "3"

(* ── Multi-equation definitions ──────────────────────────────────────────── *)

(* Equations are tried in source order, so an equation an earlier one already
   answers for can never fire. In a hand-written match an unreachable arm can
   be deliberate; a dead equation never is, since nothing at the definition
   site hints that an earlier line covered it. *)

let test_unreachable_equation_rejected () =
  err_contains "catch-all before a specific equation"
    "let f _ = 0\nlet f 1 = 1\nf 1"
    "equation 2 for 'f' is unreachable";
  err_contains "duplicate equation"
    "let b n = 2\nlet b n = 99\nb 0"
    "unreachable";
  err_contains "unreachable across several parameters"
    "let g _ _ = 2\nlet g 0 0 = 1\ng 0 0"
    "equation 2 for 'g' is unreachable"

let test_equation_messages_speak_in_equations () =
  err_contains "non-exhaustive equations name the function"
    "let f 0 = 0\nlet f 1 = 1\nf 2"
    "the equations for 'f' do not cover every case";
  (* A match the author wrote keeps the match phrasing. *)
  err_contains "hand-written match keeps its own wording"
    "match 3 with\n| 0 -> \"z\""
    "non-exhaustive match"

let test_valid_equation_groups_accepted () =
  ok "ordered equations dispatch in source order"
    "let fib 0 = 0\nlet fib 1 = 1\nlet fib n = fib (n-1) + fib (n-2)\nfib 10"
    "55";
  ok "list equations"
    "let sum [] = 0\nlet sum [h : t] = h + sum t\nsum [1,2,3]"
    "6";
  (* An unreachable arm in a hand-written match stays legal. *)
  ok "hand-written match may have a deliberate dead arm"
    "match 3 with\n| _ -> \"a\"\n| 1 -> \"b\""
    "a"

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Typechecker" [
    "field access", [
      Alcotest.test_case "map dot access rejected" `Quick test_map_dot_access_rejected;
      Alcotest.test_case "named fields checked"    `Quick test_named_field_access_checked;
      Alcotest.test_case "map patterns unaffected" `Quick test_map_patterns_still_work;
    ];
    "multi-equation", [
      Alcotest.test_case "unreachable rejected"  `Quick test_unreachable_equation_rejected;
      Alcotest.test_case "messages use equations" `Quick test_equation_messages_speak_in_equations;
      Alcotest.test_case "valid groups accepted" `Quick test_valid_equation_groups_accepted;
    ];
    "named-field types", [
      Alcotest.test_case "positional construction rejected" `Quick test_positional_construction_rejected;
      Alcotest.test_case "tuple destructuring rejected"     `Quick test_tuple_destructuring_rejected;
      Alcotest.test_case "named forms survive"              `Quick test_named_forms_survive;
      Alcotest.test_case "positional ctors unaffected"      `Quick test_positional_constructors_unaffected;
    ];
  ]
