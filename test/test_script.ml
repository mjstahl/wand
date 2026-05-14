open Wand

let run s = Runner.run_string s

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

let with_tmp src f =
  let path = Filename.temp_file "wand_test" ".wand" in
  let () = let oc = open_out path in output_string oc src; close_out oc in
  let result = f path in
  Sys.remove path; result

let test_import () =
  with_tmp {|let answer = 42|} (fun lib ->
    ok "import binding"
      (Printf.sprintf {|import %s
start answer|} lib) "42");
  with_tmp {|let double x = x * 2|} (fun lib ->
    ok "import function"
      (Printf.sprintf {|import %s
start double 21|} lib) "42");
  with_tmp {|let greeting = "hello"
let shout s = s ++ "!"|}
    (fun lib ->
      ok "import multiple bindings"
        (Printf.sprintf {|import %s
start shout greeting|} lib) "hello!")

(* ── Stdlib imports ──────────────────────────────────────────────────────── *)

let test_stdlib_import () =
  ok "List.map"
    {|import List
start map (fn x -> x * 2) [1, 2, 3]|}
    "[2, 4, 6]";
  ok "List.filter"
    {|import List
start filter (fn x -> x > 2) [1, 2, 3, 4, 5]|}
    "[3, 4, 5]";
  ok "List.length"
    {|import List
start length [1, 2, 3, 4, 5]|}
    "5";
  ok "List.reverse"
    {|import List
start reverse [1, 2, 3]|}
    "[3, 2, 1]";
  ok "List.fold_left sum"
    {|import List
start fold_left (fn acc x -> acc + x) 0 [1, 2, 3, 4, 5]|}
    "15"

(* ── Recursive top-level functions ──────────────────────────────────────── *)

let test_recursive () =
  ok "factorial"
    "let fact n = if n <= 0 then 1 else n * fact (n - 1)\nstart fact 5"
    "120";
  ok "fibonacci"
    "let fib n = if n <= 1 then n else fib (n - 1) + fib (n - 2)\nstart fib 10"
    "55"

(* ── "Did you mean?" suggestions ────────────────────────────────────────── *)

let err_suggests label input needle =
  match run input with
  | Error msg ->
    if not (contains msg needle) then
      Alcotest.failf "%s: expected '%s' in error, got: %s" label needle msg
  | Ok s -> Alcotest.failf "%s: expected error but got: %s" label s

let test_suggestions () =
  err_suggests "var typo"
    "let name = 1\nstart naem"
    "name";
  err_suggests "ctor typo"
    "type Color = Red | Green\nstart Gren"
    "Green";
  err_suggests "field typo"
    {|type Point = { x: Int, y: Int }
let p = Point { x = 1, y = 2 }
start p.xy|}
    "x";
  err_suggests "parse keyword typo"
    "lte x = 1\nstart x"
    "let"

(* ── Source locations in parse errors ───────────────────────────────────── *)

let test_locations () =
  err_suggests "line number"   "let x = 1\n= bad\nstart x" "2:";
  err_suggests "column number" "let x = 1\n= bad\nstart x" ":1"

(* ── Source locations in type errors ────────────────────────────────────── *)

let test_type_error_locations () =
  (* "let y = 1 + true": body starts at col 9, line 1 *)
  err_suggests "type error line"   "let y = 1 + true\nstart y" "1:";
  err_suggests "type error column" "let y = 1 + true\nstart y" ":9";
  (* error on line 2 *)
  err_suggests "type error line 2" "let x = 1\nlet y = x + true\nstart y" "2:"

(* ── Source locations in eval errors ────────────────────────────────────── *)

let test_eval_error_locations () =
  (* non-exhaustive match on line 3, body starts at col 9 ("match") *)
  let src = "type C = A | B\nlet x = A\nlet y = match x with | B -> 1\nstart y" in
  err_suggests "eval error line"   src "3:";
  err_suggests "eval error column" src ":9"

(* ── Multi-equation functions ───────────────────────────────────────────── *)

let test_multi_equation () =
  ok "factorial"
    {|let fact 0 = 1
let fact n = n * fact (n - 1)
start fact 5|}
    "120";
  ok "two args"
    {|let add 0 y = y
let add x 0 = x
let add x y = x + y
start "${add 3 4}, ${add 0 9}, ${add 5 0}"|}
    "7, 9, 5";
  ok "constructor patterns"
    {|type Opt = None | Some of Int
let show None     = "nothing"
let show (Some n) = "just ${n}"
start "${show None}, ${show (Some 42)}"|}
    "nothing, just 42";
  ok "wildcard catch-all"
    {|let label 1 = "one"
let label 2 = "two"
let label _ = "other"
start "${label 1}, ${label 2}, ${label 99}"|}
    "one, two, other"

(* ── Environment variables ───────────────────────────────────────────────── *)

let test_envvar () =
  let home = Sys.getenv "HOME" in
  ok "basic"           "start $HOME"                    home;
  ok "in let"          "let d = $HOME\nstart d"         home;
  ok "concatenation"   {|start $HOME ++ "/bin"|}        (home ^ "/bin");
  ok "interpolation"   {|start "home: ${$HOME}"|}       ("home: " ^ home);
  ok "string shorthand" {|start "home: $HOME"|}         ("home: " ^ home);
  err "unset var"      "start $WAND_UNSET_XYZ_99999"

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
      Alcotest.test_case "import"         `Quick test_import;
      Alcotest.test_case "stdlib import"   `Quick test_stdlib_import;
      Alcotest.test_case "recursive"       `Quick test_recursive;
      Alcotest.test_case "multi-equation"   `Quick test_multi_equation;
      Alcotest.test_case "env vars"         `Quick test_envvar;
      Alcotest.test_case "suggestions" `Quick test_suggestions;
      Alcotest.test_case "locations"   `Quick test_locations;
      Alcotest.test_case "type error locations" `Quick test_type_error_locations;
      Alcotest.test_case "eval error locations" `Quick test_eval_error_locations;
    ];
    "errors", [
      Alcotest.test_case "runtime errors" `Quick test_errors;
    ];
  ]
