open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

let err label input =
  match run input with
  | Error _ -> ()
  | Ok s -> Alcotest.failf "%s: expected error but got: %s" label s

(* ── Value bindings ──────────────────────────────────────────────────────── *)

let test_value_let () =
  ok "single binding" "let x = 42\nstart x" "42";
  ok "no start"       "let x = 42" "()"

let test_fn_let () =
  ok "fn shorthand" "let double x = x * 2\nstart double 5" "10";
  ok "two params"   "let add x y = x + y\nstart add 3 4" "7"

let test_chained () =
  ok "two lets"
    "let double x = x * 2\nlet quad x = double (double x)\nstart quad 3"
    "12"

(* ── Start ───────────────────────────────────────────────────────────────── *)

let test_start () =
  ok "literal"  "start 42" "42";
  ok "expr"     "start 1 + 2" "3";
  ok "no start" "let x = 1" "()"

(* ── Imports ─────────────────────────────────────────────────────────────── *)

let test_import () =
  ok "import parsed and skipped" {|import "utils"
let x = 1
start x|} "1"

(* ── Recursive top-level functions ──────────────────────────────────────── *)

let test_recursive () =
  ok "factorial"
    "let fact n = if n <= 0 then 1 else n * fact (n - 1)\nstart fact 5"
    "120";
  ok "fibonacci"
    "let fib n = if n <= 1 then n else fib (n - 1) + fib (n - 2)\nstart fib 10"
    "55"

(* ── Errors ──────────────────────────────────────────────────────────────── *)

let test_errors () =
  err "unbound in start" "start x";
  err "unbound in let"   "let x = y\nstart x"

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Script" [
    "top-level", [
      Alcotest.test_case "value let" `Quick test_value_let;
      Alcotest.test_case "fn let"    `Quick test_fn_let;
      Alcotest.test_case "chained"   `Quick test_chained;
      Alcotest.test_case "start"     `Quick test_start;
      Alcotest.test_case "import"    `Quick test_import;
      Alcotest.test_case "recursive" `Quick test_recursive;
    ];
    "errors", [
      Alcotest.test_case "runtime errors" `Quick test_errors;
    ];
  ]
