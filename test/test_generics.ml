open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

let err label input =
  match run input with
  | Error _ -> ()
  | Ok s -> Alcotest.failf "%s: expected error but got: %s" label s

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

let err_contains label input needle =
  match run input with
  | Error msg ->
    if not (contains msg needle) then
      Alcotest.failf "%s: expected '%s' in error, got: %s" label needle msg
  | Ok s -> Alcotest.failf "%s: expected error but got: %s" label s

(* ── Parsing generic type declarations ────────────────────────────────────── *)

let test_parse () =
  ok "single param"
    "type Box 'a = Box 'a; 1" "1";
  ok "multi param"
    "type Pair 'a 'b = Pair 'a 'b; 1" "1"

(* ── Construction and pattern matching ────────────────────────────────────── *)

let test_construct_match () =
  ok "construct Some"
    "type Option 'a = None | Some 'a
let is_some o = match o with | Some _ -> true | None -> false
is_some (Some 3)"
    "true";
  ok "construct None"
    "type Option 'a = None | Some 'a
let is_some o = match o with | Some _ -> true | None -> false
is_some None"
    "false";
  ok "extract value"
    "type Option 'a = None | Some 'a
let get_or d o = match o with | Some v -> v | None -> d
get_or 0 (Some 42)"
    "42"

(* ── No cross-instantiation collision ─────────────────────────────────────── *)

let test_no_collision () =
  ok "same generic type at two different type args"
    "type Box 'a = Box 'a
let unbox (Box x) = x
(unbox (Box 1), unbox (Box \"s\"))"
    "(1, s)"

(* ── Negative cases ────────────────────────────────────────────────────────── *)

let test_negative () =
  err "undeclared type variable"
    "type Foo 'a = Bar 'b; 1";
  err_contains "undeclared type variable message"
    "type Foo 'a = Bar 'b; 1"
    "'b";
  err "wrong type at use site"
    "type Option 'a = None | Some 'a
let f (x : Int) = x
f (Some 1)";
  err "arity mismatch"
    "type Box 'a = Box 'a
match Box 1 with | Box a b -> a"

(* ── Option module ────────────────────────────────────────────────────────── *)

let test_option_module () =
  ok "map"
    "import Option
match Option.map (fn x -> x + 1) (Some 1) with | Some v -> v | None -> 0"
    "2";
  ok "and_then"
    "import Option
let half x = if x % 2 == 0 then Some (x / 2) else None
match Option.and_then half (Some 4) with | Some v -> v | None -> -1"
    "2";
  ok "default"
    "import Option
Option.default 0 None"
    "0";
  ok "to_result ok"
    "import Option
match Option.to_result \"missing\" (Some 5) with | Ok v -> v | Error _ -> 0"
    "5";
  ok "to_result error"
    "import Option
match Option.to_result \"missing\" None with | Ok _ -> \"\" | Error e -> e"
    "missing";
  ok "get! present"
    "import Option
Option.get! (Some 7)"
    "7";
  err "get! absent raises"
    "import Option
Option.get! None"

(* ── Result generalization ────────────────────────────────────────────────── *)

let test_result_generic () =
  ok "custom error type"
    "import String
type ParseError = UnexpectedToken String | UnexpectedEof
let parse s : Result ParseError Int =
  if s == \"\" then Error UnexpectedEof
  else match String.to_int s with
  | Ok n -> Ok n
  | Error _ -> Error (UnexpectedToken s)
match parse \"abc\" with
| Ok n -> \"ok\"
| Error (UnexpectedToken t) -> \"bad: ${t}\"
| Error UnexpectedEof -> \"eof\""
    "bad: abc";
  ok "plain string error still works"
    "let r : Result String Int = Ok 1
match r with | Ok n -> n | Error _ -> 0"
    "1"

(* ── Suite ─────────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Generics" [
    "parsing", [
      Alcotest.test_case "type param declarations" `Quick test_parse;
    ];
    "construction and matching", [
      Alcotest.test_case "construct/match" `Quick test_construct_match;
      Alcotest.test_case "no collision"    `Quick test_no_collision;
    ];
    "errors", [
      Alcotest.test_case "negative cases" `Quick test_negative;
    ];
    "Option module", [
      Alcotest.test_case "Option" `Quick test_option_module;
    ];
    "Result generalization", [
      Alcotest.test_case "custom error types" `Quick test_result_generic;
    ];
  ]
