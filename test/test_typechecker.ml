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

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Typechecker" [
    "field access", [
      Alcotest.test_case "map dot access rejected" `Quick test_map_dot_access_rejected;
      Alcotest.test_case "named fields checked"    `Quick test_named_field_access_checked;
      Alcotest.test_case "map patterns unaffected" `Quick test_map_patterns_still_work;
    ];
    "named-field types", [
      Alcotest.test_case "positional construction rejected" `Quick test_positional_construction_rejected;
      Alcotest.test_case "tuple destructuring rejected"     `Quick test_tuple_destructuring_rejected;
      Alcotest.test_case "named forms survive"              `Quick test_named_forms_survive;
      Alcotest.test_case "positional ctors unaffected"      `Quick test_positional_constructors_unaffected;
    ];
  ]
