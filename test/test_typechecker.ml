open Wand

let infer s =
  Lexer.tokenize s
  |> Parser.parse_expr
  |> Typechecker.infer_expr
  |> Result.map Typechecker.string_of_typ

let ty = Alcotest.(result string string)

let ok label input expected =
  Alcotest.(check ty) label (Ok expected) (infer input)

let err label input =
  match infer input with
  | Error _ -> ()
  | Ok t -> Alcotest.failf "%s: expected type error but got: %s" label t

(* ── Literals ─────────────────────────────────────────────────────────────── *)

let test_prim_lits () =
  ok "int"    "42"        "Int";
  ok "float"  "3.14"      "Float";
  ok "string" {|"hello"|} "String";
  ok "true"   "true"      "Bool";
  ok "false"  "false"     "Bool";
  ok "unit"   "()"        "Unit"

let test_domain_lits () =
  ok "path"     "/etc/foo"            "Path";
  ok "date"     "2024-01-15"          "Date";
  ok "time"     "14:30:00"            "Time";
  ok "duration" "5min"                "Duration";
  ok "url"      "https://example.com" "Url";
  ok "ipv4"     "192.168.1.1"         "IPv4";
  ok "cidr"     "10.0.0.0/24"         "CIDR";
  ok "port"     ":8080"               "Port";
  ok "version"  "1.2.3"               "Version";
  ok "size"     "10MB"                "Size"

(* ── Variables ────────────────────────────────────────────────────────────── *)

let test_vars () =
  ok "int var"    "let x = 1 in x"       "Int";
  ok "bool var"   "let x = true in x"    "Bool";
  ok "string var" {|let x = "hi" in x|}  "String";
  ok "shadow"     "let x = 1 in let x = true in x" "Bool"

(* ── Arithmetic & comparison ──────────────────────────────────────────────── *)

let test_arith () =
  ok "add" "1 + 2" "Int";
  ok "sub" "1 - 2" "Int";
  ok "mul" "2 * 3" "Int";
  ok "div" "6 / 2" "Int"

let test_cmp () =
  ok "eq int"    "1 == 1"       "Bool";
  ok "eq string" {|"a" == "b"|} "Bool";
  ok "neq"       "1 != 2"       "Bool";
  ok "lt"        "1 < 2"        "Bool";
  ok "gt"        "1 > 2"        "Bool";
  ok "lte"       "1 <= 2"       "Bool";
  ok "gte"       "1 >= 2"       "Bool"

let test_logical () =
  ok "and" "true && false" "Bool";
  ok "or"  "true || false" "Bool"

let test_unary () =
  ok "not" "!true" "Bool";
  ok "neg" "-1"    "Int"

(* ── If ───────────────────────────────────────────────────────────────────── *)

let test_if () =
  ok "int branches"
    "if true then 1 else 0"        "Int";
  ok "string branches"
    {|if true then "a" else "b"|}  "String";
  ok "nested"
    "if true then if false then 1 else 2 else 3" "Int"

(* ── Let ──────────────────────────────────────────────────────────────────── *)

let test_let () =
  ok "body arith"   "let x = 1 in x + 1"              "Int";
  ok "fn in let"    "let f = fn x -> x + 1 in f 5"    "Int";
  ok "fn shorthand" "let f x = x + 1 in f 5"          "Int";
  ok "recursive"    "let fact n = if n <= 0 then 1 else n * fact (n - 1) in fact 5" "Int";
  ok "poly id"      "let id x = x in id 1"             "Int"

(* ── Functions ────────────────────────────────────────────────────────────── *)

let test_fn () =
  ok "identity" "fn x -> x"           "'a -> 'a";
  ok "add one"  "fn x -> x + 1"       "Int -> Int";
  ok "const"    "fn x -> fn y -> x"   "'a -> 'b -> 'a";
  ok "flip"     "fn x -> fn y -> y"   "'a -> 'b -> 'b";
  ok "compose"  "fn f -> fn x -> f x" "('a -> 'b) -> 'a -> 'b"

(* ── Application ──────────────────────────────────────────────────────────── *)

let test_app () =
  ok "int result"  "(fn x -> x + 1) 5"         "Int";
  ok "bool result" "(fn x -> x) true"           "Bool";
  ok "two args"    "(fn x -> fn y -> x) 1 true" "Int"

(* ── Let polymorphism ─────────────────────────────────────────────────────── *)

let test_let_poly () =
  ok "id int"    "let id = fn x -> x in id 1"       "Int";
  ok "id bool"   "let id = fn x -> x in id true"    "Bool";
  ok "id string" {|let id = fn x -> x in id "hi"|}  "String"

(* ── Tuples ───────────────────────────────────────────────────────────────── *)

let test_tuple () =
  ok "pair"    "(1, true)"       "Int * Bool";
  ok "triple"  "(1, 2, 3)"       "Int * Int * Int";
  ok "nested"  "((1, 2), true)"  "(Int * Int) * Bool"

(* ── Lists ────────────────────────────────────────────────────────────────── *)

let test_list () =
  ok "empty"   "[]"           "List 'a";
  ok "ints"    "[1, 2, 3]"    "List Int";
  ok "strings" {|["a", "b"]|} "List String"

(* ── Match ────────────────────────────────────────────────────────────────── *)

let test_match () =
  ok "bool scrutinee"
    "match true with\n| true -> 1\n| false -> 0"
    "Int";
  ok "wildcard arm"
    "match 1 with\n| 1 -> true\n| _ -> false"
    "Bool";
  ok "guard"
    "fn n -> match n with\n| x when x > 0 -> true\n| _ -> false"
    "Int -> Bool"

(* ── Pipeline ─────────────────────────────────────────────────────────────── *)

let test_pipeline () =
  ok "pipeline"    "1 |> fn x -> x + 1"                    "Int";
  ok "double pipe" "1 |> fn x -> x + 1 |> fn x -> x * 2"  "Int"

(* ── Type errors ──────────────────────────────────────────────────────────── *)

let test_errors () =
  err "add bool"        "1 + true";
  err "if not bool"     "if 1 then 2 else 3";
  err "branch mismatch" "if true then 1 else true";
  err "apply non-fn"    "1 2";
  err "list mismatch"   "[1, true]"

(* ── Program-level inference ──────────────────────────────────────────────── *)

let infer_prog s =
  Lexer.tokenize s
  |> Parser.parse_program
  |> Typechecker.infer_program
  |> Result.map Typechecker.string_of_typ

let ok_prog label input expected =
  Alcotest.(check ty) label (Ok expected) (infer_prog input)

let err_prog label input =
  match infer_prog input with
  | Error _ -> ()
  | Ok t -> Alcotest.failf "%s: expected type error but got: %s" label t

let test_enum_types () =
  ok_prog "nullary"  "type Color = Red | Green; Red"   "Color";
  ok_prog "second"   "type Color = Red | Green; Green" "Color"

let test_payload_types () =
  ok_prog "single arg" "type Wrap = Wrap Int; Wrap 42"           "Wrap";
  ok_prog "two args"   "type Pair = Pair (Int, Int); Pair 3 4"  "Pair"

let test_match_ctor () =
  ok_prog "nullary arms"
    {|type Color = Red | Green
let f c = match c with
| Red   -> 1
| Green -> 2
f Red|}
    "Int";
  ok_prog "payload arm"
    {|type Wrap = Wrap Int
let unwrap w = match w with
| Wrap n -> n
unwrap (Wrap 42)|}
    "Int"

let test_named_field_typedef () =
  ok_prog "field access"
    {|type Point (x Int, y Int)
let p = Point (x = 1, y = 2)
p.x|}
    "Int";
  ok_prog "second field"
    {|type Point (x Int, y Int)
let p = Point (x = 1, y = 2)
p.y|}
    "Int"

let test_ctor_errors () =
  err_prog "unknown ctor"   "Bogus";
  err_prog "wrong arg type" "type Wrap = Wrap Int; Wrap true"

(* ── Type annotations ────────────────────────────────────────────────────── *)

let test_annot () =
  ok_prog "value annot"    "let x : Int = 42; x"          "Int";
  ok_prog "fn return annot" "let double x : Int = x * 2; double 3" "Int";
  err_prog "annot mismatch" "let x : Bool = 42"

(* ── Suite ────────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Typechecker" [
    "literals", [
      Alcotest.test_case "primitives"  `Quick test_prim_lits;
      Alcotest.test_case "domain"      `Quick test_domain_lits;
    ];
    "expressions", [
      Alcotest.test_case "variables"   `Quick test_vars;
      Alcotest.test_case "arithmetic"  `Quick test_arith;
      Alcotest.test_case "comparison"  `Quick test_cmp;
      Alcotest.test_case "logical"     `Quick test_logical;
      Alcotest.test_case "unary"       `Quick test_unary;
      Alcotest.test_case "if"          `Quick test_if;
      Alcotest.test_case "let"         `Quick test_let;
      Alcotest.test_case "fn"          `Quick test_fn;
      Alcotest.test_case "application" `Quick test_app;
      Alcotest.test_case "let poly"    `Quick test_let_poly;
      Alcotest.test_case "tuple"       `Quick test_tuple;
      Alcotest.test_case "list"        `Quick test_list;
      Alcotest.test_case "match"       `Quick test_match;
      Alcotest.test_case "pipeline"    `Quick test_pipeline;
    ];
    "errors", [
      Alcotest.test_case "type errors" `Quick test_errors;
    ];
    "type definitions", [
      Alcotest.test_case "enum types"     `Quick test_enum_types;
      Alcotest.test_case "payload types"  `Quick test_payload_types;
      Alcotest.test_case "match ctor"     `Quick test_match_ctor;
      Alcotest.test_case "record typedef" `Quick test_named_field_typedef;
      Alcotest.test_case "ctor errors"    `Quick test_ctor_errors;
    ];
    "annotations", [
      Alcotest.test_case "type annotations" `Quick test_annot;
    ];
  ]
