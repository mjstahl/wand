open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

let err label input =
  match run input with
  | Error _ -> ()
  | Ok s -> Alcotest.failf "%s: expected error but got: %s" label s

(* ── Enum-style variants (no payload) ───────────────────────────────────── *)

let test_enum () =
  ok "nullary constructor"
    "type Color = Red | Green | Blue\nstart Red"
    "Red";
  ok "constructor equality"
    "type Color = Red | Green | Blue\nstart Red == Red"
    "true";
  ok "constructor inequality"
    "type Color = Red | Green | Blue\nstart Red == Green"
    "false"

(* ── Variants with payloads ─────────────────────────────────────────────── *)

let test_payload () =
  ok "single payload"
    "type Wrap = Wrap of Int\nstart Wrap 42"
    "Wrap(42)";
  ok "two payloads"
    "type Pair = Pair of Int * Int\nstart Pair 3 4"
    "Pair(3, 4)"

(* ── Pattern matching on variants ───────────────────────────────────────── *)

let test_match_variant () =
  ok "match nullary"
    {|type Color = Red | Green | Blue
let describe c = match c with
| Red   -> "red"
| Green -> "green"
| Blue  -> "blue"
start describe Green|}
    "green";
  ok "match payload"
    {|type Rect = Rect of Int * Int
let area r = match r with
| Rect w h -> w * h
start area (Rect 3 4)|}
    "12"

(* ── Record types ────────────────────────────────────────────────────────── *)

let test_record_type () =
  ok "construct and access"
    {|type Point = { x: Int, y: Int }
let p = Point { x = 1, y = 2 }
start p.x|}
    "1";
  ok "record field"
    {|type Point = { x: Int, y: Int }
let origin = Point { x = 0, y = 0 }
start origin.y|}
    "0"

(* ── Errors ──────────────────────────────────────────────────────────────── *)

let test_errors () =
  err "unknown constructor" "start Bogus";
  err "wrong arity"
    "type Wrap = Wrap of Int\nstart Wrap 1 2"

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Typedef" [
    "variants", [
      Alcotest.test_case "enum"          `Quick test_enum;
      Alcotest.test_case "payload"       `Quick test_payload;
      Alcotest.test_case "match variant" `Quick test_match_variant;
    ];
    "records", [
      Alcotest.test_case "record type"   `Quick test_record_type;
    ];
    "errors", [
      Alcotest.test_case "type errors"   `Quick test_errors;
    ];
  ]
