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
    "type Color = Red | Green | Blue; Red"
    "Red";
  ok "constructor equality"
    "type Color = Red | Green | Blue; Red == Red"
    "true";
  ok "constructor inequality"
    "type Color = Red | Green | Blue; Red == Green"
    "false"

(* ── Variants with payloads ─────────────────────────────────────────────── *)

let test_payload () =
  ok "single payload"
    "type Wrap = Wrap Int; Wrap 42"
    "Wrap(42)";
  ok "two payloads"
    "type Pair = Pair (Int, Int); Pair 3 4"
    "Pair(3, 4)"

(* ── Pattern matching on variants ───────────────────────────────────────── *)

let test_match_variant () =
  ok "match nullary"
    {|type Color = Red | Green | Blue
let describe c = match c with
| Red   -> "red"
| Green -> "green"
| Blue  -> "blue"
describe Green|}
    "green";
  ok "match payload"
    {|type Rect = Rect (Int, Int)
let area r = match r with
| Rect w h -> w * h
area (Rect 3 4)|}
    "12"

(* ── Record types ────────────────────────────────────────────────────────── *)

let test_record_type () =
  ok "construct and access"
    {|type Point = { x: Int, y: Int }
let p = Point { x = 1, y = 2 }
p.x|}
    "1";
  ok "record field"
    {|type Point = { x: Int, y: Int }
let origin = Point { x = 0, y = 0 }
origin.y|}
    "0"

(* ── Record patterns ─────────────────────────────────────────────────────── *)

let test_record_pat () =
  ok "destructure named record"
    {|type Point = { x: Int, y: Int }
let p = Point { x = 3, y = 4 }
let sum = match p with | { x = a, y = b } -> a + b
sum|}
    "7";
  ok "shorthand binding"
    {|type Point = { x: Int, y: Int }
let p = Point { x = 10, y = 20 }
let get_x = match p with | { x } -> x
get_x|}
    "10";
  ok "wildcard field"
    {|type Point = { x: Int, y: Int }
let p = Point { x = 5, y = 99 }
let get_x = match p with | { x = v, y = _ } -> v
get_x|}
    "5";
  ok "in local let binding"
    {|type Point = { x: Int, y: Int }
let add_coords p =
  let { x = a, y = b } = p in
  a + b
add_coords (Point { x = 7, y = 8 })|}
    "15"

let test_record_pat_errors () =
  err "unknown field in pattern"
    {|type Point = { x: Int, y: Int }
let p = Point { x = 1, y = 2 }
let sum = match p with | { x = a, z = b } -> a + b
sum|}

(* ── Errors ──────────────────────────────────────────────────────────────── *)

let test_errors () =
  err "unknown constructor" "Bogus";
  err "wrong arity"
    "type Wrap = Wrap Int; Wrap 1 2"

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Typedef" [
    "variants", [
      Alcotest.test_case "enum"          `Quick test_enum;
      Alcotest.test_case "payload"       `Quick test_payload;
      Alcotest.test_case "match variant" `Quick test_match_variant;
    ];
    "records", [
      Alcotest.test_case "record type"    `Quick test_record_type;
      Alcotest.test_case "record pattern" `Quick test_record_pat;
      Alcotest.test_case "record pattern errors" `Quick test_record_pat_errors;
    ];
    "errors", [
      Alcotest.test_case "type errors"   `Quick test_errors;
    ];
  ]
