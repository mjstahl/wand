open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

let err label input =
  match run input with
  | Error _ -> ()
  | Ok s -> Alcotest.failf "%s: expected error but got: %s" label s

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let with_named name src f =
  let dir = Filename.get_temp_dir_name () in
  let path = Filename.concat dir (name ^ ".wand") in
  let oc = open_out path in
  output_string oc src; close_out oc;
  let result = (try f path with e -> Sys.remove path; raise e) in
  Sys.remove path; result

(* ── let x = import ./path ───────────────────────────────────────────────── *)

let test_let_import () =
  with_named "mylib" {|let answer = 42|} (fun path ->
    ok "whole module bound to name"
      (Printf.sprintf {|let mylib = import %s
mylib.answer|} path)
      "42");
  with_named "mylib" {|let double x = x * 2|} (fun path ->
    ok "function call via bound name"
      (Printf.sprintf {|let mylib = import %s
mylib.double 21|} path)
      "42");
  with_named "mylib" {|let x = 1
let y = 2|} (fun path ->
    ok "multiple fields accessible"
      (Printf.sprintf {|let mylib = import %s
mylib.x + mylib.y|} path)
      "3")

(* ── Capital name convention ─────────────────────────────────────────────── *)

let test_capital_name () =
  with_named "mylib" {|let greet = "hello"|} (fun path ->
    ok "capital name works"
      (Printf.sprintf {|let Mylib = import %s
Mylib.greet|} path)
      "hello")

(* ── let x = import Stdlib ───────────────────────────────────────────────── *)

let test_stdlib_let_import () =
  ok "stdlib bound to custom name"
    {|let L = import List
L.length [1, 2, 3]|}
    "3";
  ok "stdlib with different local name"
    {|let Strs = import String
Strs.upper "hello"|}
    "HELLO"

(* ── Destructured import: let [foo = bar] = import ./path ───────────────── *)

let test_destructured_import () =
  with_named "utils" {|let foo = 10
let bar = 20|} (fun path ->
    ok "destructure two fields"
      (Printf.sprintf {|let [foo = a, bar = b] = import %s
a + b|} path)
      "30");
  with_named "utils" {|let double x = x * 2|} (fun path ->
    ok "destructure function"
      (Printf.sprintf {|let [double = dbl] = import %s
dbl 21|} path)
      "42")

(* ── Shorthand list-style destructure: let [foo, bar] = import ./path ───── *)

let test_shorthand_destructure () =
  with_named "utils" {|let answer = 42
let pi = 3|} (fun path ->
    ok "shorthand list destructure"
      (Printf.sprintf {|let [answer, pi] = import %s
answer + pi|} path)
      "45")

(* ── Private symbols (leading _) ─────────────────────────────────────────── *)

let test_private_symbols () =
  with_named "utils" {|let _helper x = x * 2
let double x = _helper x|} (fun path ->
    ok "public symbol callable"
      (Printf.sprintf {|let utils = import %s
utils.double 5|} path)
      "10");
  with_named "utils" {|let _secret = 42
let public = 1|} (fun path ->
    err "private symbol not accessible"
      (Printf.sprintf {|let utils = import %s
utils._secret|} path))

(* ── Error: missing field in destructure ────────────────────────────────── *)

let test_destructure_missing_field () =
  with_named "utils" {|let foo = 1|} (fun path ->
    err "missing field gives error"
      (Printf.sprintf {|let [bar = x] = import %s
x|} path))

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Imports" [
    "let import", [
      Alcotest.test_case "whole module"    `Quick test_let_import;
      Alcotest.test_case "capital name"    `Quick test_capital_name;
      Alcotest.test_case "stdlib import"   `Quick test_stdlib_let_import;
    ];
    "destructure", [
      Alcotest.test_case "map pattern"     `Quick test_destructured_import;
      Alcotest.test_case "list shorthand"  `Quick test_shorthand_destructure;
    ];
    "private", [
      Alcotest.test_case "private symbols" `Quick test_private_symbols;
    ];
    "errors", [
      Alcotest.test_case "missing field"   `Quick test_destructure_missing_field;
    ];
  ]
