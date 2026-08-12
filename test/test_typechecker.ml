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

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Typechecker" [
    "field access", [
      Alcotest.test_case "map dot access rejected" `Quick test_map_dot_access_rejected;
      Alcotest.test_case "named fields checked"    `Quick test_named_field_access_checked;
      Alcotest.test_case "map patterns unaffected" `Quick test_map_patterns_still_work;
    ];
  ]
