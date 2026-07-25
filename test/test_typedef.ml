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
    "type Pair = Pair Int Int; Pair 3 4"
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
    {|type Rect = Rect Int Int
let area r = match r with
| Rect w h -> w * h
area (Rect 3 4)|}
    "12"

(* ── Single-constructor shorthand (named fields) ─────────────────────────── *)

let test_named_fields () =
  ok "construct and access"
    {|type Point (x : Int, y : Int)
let p = Point (x = 1, y = 2)
p.x|}
    "1";
  ok "second field"
    {|type Point (x : Int, y : Int)
let origin = Point (x = 0, y = 0)
origin.y|}
    "0";
  ok "field on function result"
    {|type Circle (radius : Int)
let unit_circle = Circle (radius = 1)
unit_circle.radius|}
    "1"

(* ── Named constructor patterns ──────────────────────────────────────────── *)

let test_named_pat () =
  ok "destructure named fields"
    {|type Point (x : Int, y : Int)
let p = Point (x = 3, y = 4)
let sum = match p with | Point (x = a, y = b) -> a + b
sum|}
    "7";
  ok "wildcard field"
    {|type Point (x : Int, y : Int)
let p = Point (x = 5, y = 99)
let get_x = match p with | Point (x = v, y = _) -> v
get_x|}
    "5";
  ok "in local let binding"
    {|type Point (x : Int, y : Int)
let add_coords p =
  let Point (x = a, y = b) = p in
  a + b
add_coords (Point (x = 7, y = 8))|}
    "15"

(* ── Single-constructor shorthand destructuring ──────────────────────────── *)

let test_single_ctor_destructure () =
  ok "single field shorthand let"
    {|type Circle (radius : Int)
let c = Circle (radius = 7)
let (r) = c
r|}
    "7";
  ok "multi field shorthand let"
    {|type Point (x : Int, y : Int)
let p = Point (x = 3, y = 4)
let (a, b) = p
"${a}, ${b}"|}
    "3, 4";
  ok "match arm shorthand"
    {|type Circle (radius : Int)
let c = Circle (radius = 9)
match c with | (r) -> r|}
    "9";
  ok "in local let inside fn"
    {|type Circle (radius : Int)
let area c =
  let (r) = c in
  r * r
area (Circle (radius = 5))|}
    "25"

let test_named_pat_errors () =
  err "unknown field in pattern"
    {|type Point (x : Int, y : Int)
let p = Point (x = 1, y = 2)
let sum = match p with | Point (x = a, z = b) -> a + b
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
    "named fields", [
      Alcotest.test_case "named fields"              `Quick test_named_fields;
      Alcotest.test_case "named patterns"            `Quick test_named_pat;
      Alcotest.test_case "named pattern errors"      `Quick test_named_pat_errors;
      Alcotest.test_case "shorthand destructuring"   `Quick test_single_ctor_destructure;
    ];
    "errors", [
      Alcotest.test_case "type errors"   `Quick test_errors;
    ];
  ]
