open Wand

let eval s =
  Lexer.tokenize s
  |> Parser.parse_expr
  |> Evaluator.eval_expr
  |> Result.map Evaluator.show_value

let v = Alcotest.(result string string)

let ok label input expected =
  Alcotest.(check v) label (Ok expected) (eval input)

let err label input =
  match eval input with
  | Error _ -> ()
  | Ok s -> Alcotest.failf "%s: expected error but got: %s" label s

(* ── Literals ─────────────────────────────────────────────────────────────── *)

let test_prim_lits () =
  ok "int"    "42"        "42";
  ok "float"  "3.14"      "3.14";
  ok "string" {|"hello"|} "hello";
  ok "true"   "true"      "true";
  ok "false"  "false"     "false";
  ok "unit"   "()"        "()"

let test_domain_lits () =
  ok "path"     "/etc/foo"            "/etc/foo";
  ok "date"     "2024-01-15"          "2024-01-15";
  ok "time"     "14:30:00"            "14:30:00";
  ok "duration" "5min"                "5min";
  ok "url"      "https://example.com" "https://example.com";
  ok "ipv4"     "192.168.1.1"         "192.168.1.1";
  ok "version"  "1.2.3"               "1.2.3";
  ok "size"     "10MB"                "10MB"

(* ── Arithmetic ───────────────────────────────────────────────────────────── *)

let test_arith () =
  ok "add"  "1 + 2"   "3";
  ok "sub"  "5 - 3"   "2";
  ok "mul"  "3 * 4"   "12";
  ok "div"  "10 / 2"  "5";
  ok "neg"  "-7"      "-7";
  ok "prec" "2 + 3 * 4" "14"

let test_cmp () =
  ok "eq true"   "1 == 1"  "true";
  ok "eq false"  "1 == 2"  "false";
  ok "neq"       "1 != 2"  "true";
  ok "lt true"   "1 < 2"   "true";
  ok "lt false"  "2 < 1"   "false";
  ok "gt"        "3 > 2"   "true";
  ok "lte"       "2 <= 2"  "true";
  ok "gte"       "3 >= 4"  "false"

let test_logical () =
  ok "and tt" "true && true"   "true";
  ok "and tf" "true && false"  "false";
  ok "or tf"  "true || false"  "true";
  ok "or ff"  "false || false" "false";
  ok "not t"  "!true"          "false";
  ok "not f"  "!false"         "true"

(* ── If ───────────────────────────────────────────────────────────────────── *)

let test_if () =
  ok "true branch"  "if true then 1 else 0"   "1";
  ok "false branch" "if false then 1 else 0"  "0";
  ok "nested"
    "if true then if false then 1 else 2 else 3" "2";
  ok "cond expr"
    "if 1 == 1 then \"yes\" else \"no\""         "yes"

(* ── Let ──────────────────────────────────────────────────────────────────── *)

let test_let () =
  ok "simple"   "let x = 42 in x"          "42";
  ok "arith"    "let x = 10 in x + 5"      "15";
  ok "shadow"   "let x = 1 in let x = 2 in x" "2";
  ok "wildcard" "let _ = 1 in 99"          "99";
  ok "tuple pat"
    "let (a, b) = (3, 4) in a + b"        "7"

(* ── Functions ────────────────────────────────────────────────────────────── *)

let test_fn () =
  ok "identity"   "(fn x -> x) 42"          "42";
  ok "add one"    "(fn x -> x + 1) 5"       "6";
  ok "two args"   "(fn x -> fn y -> x + y) 3 4" "7";
  ok "wildcard"   "(fn _ -> 99) true"       "99";
  ok "closure"
    "let n = 10 in (fn x -> x + n) 5"     "15"

(* ── Higher-order ─────────────────────────────────────────────────────────── *)

let test_higher_order () =
  ok "apply"
    "let apply = fn f -> fn x -> f x in
     apply (fn x -> x * 2) 5"
    "10";
  ok "compose"
    "let f = fn x -> x + 1 in
     let g = fn x -> x * 2 in
     f (g 3)"
    "7"

(* ── Match ────────────────────────────────────────────────────────────────── *)

let test_match () =
  ok "first arm"
    "match 1 with\n| 1 -> true\n| _ -> false"  "true";
  ok "wildcard arm"
    "match 2 with\n| 1 -> true\n| _ -> false"  "false";
  ok "bool match"
    "match true with\n| true -> 1\n| false -> 0" "1";
  ok "guard pass"
    "match 5 with\n| x when x > 3 -> true\n| _ -> false" "true";
  ok "guard fail"
    "match 2 with\n| x when x > 3 -> true\n| _ -> false" "false"

(* ── Tuples ───────────────────────────────────────────────────────────────── *)

let test_tuple () =
  ok "pair"    "(1, 2)"       "(1, 2)";
  ok "triple"  "(1, 2, 3)"    "(1, 2, 3)";
  ok "mixed"   "(1, true)"    "(1, true)";
  ok "nested"  "((1, 2), 3)"  "((1, 2), 3)"

(* ── Lists ────────────────────────────────────────────────────────────────── *)

let test_list () =
  ok "empty"    "[]"          "[]";
  ok "ints"     "[1, 2, 3]"   "[1, 2, 3]";
  ok "strings"  {|["a", "b"]|} "[a, b]";
  ok "computed" "[1 + 1, 2 + 2]" "[2, 4]"

(* ── Pipeline ─────────────────────────────────────────────────────────────── *)

let test_pipeline () =
  ok "pipeline"     "5 |> fn x -> x + 1"                   "6";
  ok "double"       "5 |> fn x -> x + 1 |> fn x -> x * 2"  "12";
  ok "with let"
    "let double = fn x -> x * 2 in
     3 |> double"
    "6"

(* ── Recursive let ────────────────────────────────────────────────────────── *)

let test_recursive_let () =
  ok "factorial"
    "let fact n = if n <= 0 then 1 else n * fact (n - 1) in fact 5"
    "120";
  ok "fibonacci"
    "let fib n = if n <= 1 then n else fib (n - 1) + fib (n - 2) in fib 10"
    "55";
  ok "countdown"
    "let count n = if n == 0 then 0 else count (n - 1) in count 100"
    "0"

(* ── Errors ───────────────────────────────────────────────────────────────── *)

let test_errors () =
  err "unbound var"     "x";
  err "no match"        "match 5 with\n| 1 -> true";
  err "apply non-fn"    "1 2"

(* ── Suite ────────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Evaluator" [
    "literals", [
      Alcotest.test_case "primitives"    `Quick test_prim_lits;
      Alcotest.test_case "domain"        `Quick test_domain_lits;
    ];
    "expressions", [
      Alcotest.test_case "arithmetic"    `Quick test_arith;
      Alcotest.test_case "comparison"    `Quick test_cmp;
      Alcotest.test_case "logical"       `Quick test_logical;
      Alcotest.test_case "if"            `Quick test_if;
      Alcotest.test_case "let"           `Quick test_let;
      Alcotest.test_case "fn"            `Quick test_fn;
      Alcotest.test_case "higher-order"  `Quick test_higher_order;
      Alcotest.test_case "match"         `Quick test_match;
      Alcotest.test_case "tuple"         `Quick test_tuple;
      Alcotest.test_case "list"          `Quick test_list;
      Alcotest.test_case "pipeline"      `Quick test_pipeline;
      Alcotest.test_case "recursive let" `Quick test_recursive_let;
    ];
    "errors", [
      Alcotest.test_case "runtime errors" `Quick test_errors;
    ];
  ]
