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
  ok "single binding" "let x = 42; x" "42";
  ok "no start"       "let x = 42" "()"

let test_fn_let () =
  ok "fn shorthand" "let double x = x * 2; double 5" "10";
  ok "two params"   "let add x y = x + y; add 3 4" "7"

let test_chained () =
  ok "two lets"
    "let double x = x * 2; let quad x = double (double x); quad 3"
    "12"

(* ── Start ───────────────────────────────────────────────────────────────── *)

let test_start () =
  ok "literal"  "42" "42";
  ok "expr"     "1 + 2" "3";
  ok "no start" "let x = 1" "()"

(* ── Imports ─────────────────────────────────────────────────────────────── *)

let with_tmp src f =
  let path = Filename.temp_file "wand_test" ".wand" in
  let () = let oc = open_out path in output_string oc src; close_out oc in
  let result = f path in
  Sys.remove path; result

(* Create a temp file with a predictable basename so the namespace name is known *)
let with_named name src f =
  let dir = Filename.get_temp_dir_name () in
  let path = Filename.concat dir (name ^ ".wand") in
  let () = let oc = open_out path in output_string oc src; close_out oc in
  let result = (try f path with e -> Sys.remove path; raise e) in
  Sys.remove path; result

let test_import () =
  with_named "Lib" {|let answer = 42|} (fun lib ->
    ok "import binding"
      (Printf.sprintf {|import %s
Lib.answer|} lib) "42");
  with_named "Lib" {|let double x = x * 2|} (fun lib ->
    ok "import function"
      (Printf.sprintf {|import %s
Lib.double 21|} lib) "42");
  with_named "Lib" {|let greeting = "hello"
let shout s = s ++ "!"|}
    (fun lib ->
      ok "import multiple bindings"
        (Printf.sprintf {|import %s
Lib.shout Lib.greeting|} lib) "hello!")

(* ── Stdlib imports ──────────────────────────────────────────────────────── *)

let test_stdlib_import () =
  ok "List.map"
    {|import List
List.map (fn x -> x * 2) [1, 2, 3]|}
    "[2, 4, 6]";
  ok "List.filter"
    {|import List
List.filter (fn x -> x > 2) [1, 2, 3, 4, 5]|}
    "[3, 4, 5]";
  ok "List.length"
    {|import List
List.length [1, 2, 3, 4, 5]|}
    "5";
  ok "List.reverse"
    {|import List
List.reverse [1, 2, 3]|}
    "[3, 2, 1]";
  ok "List.fold_left sum"
    {|import List
List.fold_left (fn acc x -> acc + x) 0 [1, 2, 3, 4, 5]|}
    "15"

(* ── Recursive top-level functions ──────────────────────────────────────── *)

let test_recursive () =
  ok "factorial"
    "let fact n = if n <= 0 then 1 else n * fact (n - 1); fact 5"
    "120";
  ok "fibonacci"
    "let fib n = if n <= 1 then n else fib (n - 1) + fib (n - 2); fib 10"
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
    "let name = 1; naem"
    "name";
  err_suggests "ctor typo"
    "type Color = Red | Green; Gren"
    "Green";
  err_suggests "field typo"
    {|type Point (x : Int, y : Int)
let p = Point (x = 1, y = 2)
p.xy|}
    "x";
  err_suggests "parse keyword typo"
    "lte x = 1; x"
    "let";
  err_suggests "missing stdlib import"
    "List.map (fn x -> x + 1) [1, 2, 3]"
    "forget to import the standard library List"

(* ── Source locations in parse errors ───────────────────────────────────── *)

let test_locations () =
  err_suggests "line number"   "let x = 1\n= bad\nx" "2:";
  err_suggests "column number" "let x = 1\n= bad\nx" ":1"

(* ── Source locations in type errors ────────────────────────────────────── *)

let test_type_error_locations () =
  (* "let y = 1 + true": body starts at col 9, line 1 *)
  err_suggests "type error line"   "let y = 1 + true\ny" "1:";
  err_suggests "type error column" "let y = 1 + true\ny" ":9";
  (* error on line 2 *)
  err_suggests "type error line 2" "let x = 1\nlet y = x + true\ny" "2:";
  (* error inside if branch: line 3 *)
  err_suggests "if branch line" "let x =\n  if true then\n    1 + true\n  else 0\nx" "3:";
  (* error inside match arm: line 3 *)
  err_suggests "match arm line" "let f n =\n  match n with\n  | 0 -> 1 + true\n  | _ -> 0\nf 1" "3:"

(* ── Source locations in eval errors ────────────────────────────────────── *)

let test_eval_error_locations () =
  (* non-exhaustive match on line 3, body starts at col 9 ("match") *)
  let src = "type C = A | B\nlet x = A\nlet y = match x with | B -> 1\ny" in
  err_suggests "eval error line"   src "3:";
  err_suggests "eval error column" src ":9"

(* ── Multi-equation functions ───────────────────────────────────────────── *)

let test_multi_equation () =
  ok "factorial"
    {|let fact 0 = 1
let fact n = n * fact (n - 1)
fact 5|}
    "120";
  ok "two args"
    {|let add 0 y = y
let add x 0 = x
let add x y = x + y
"${add 3 4}, ${add 0 9}, ${add 5 0}"|}
    "7, 9, 5";
  ok "constructor patterns"
    {|type Opt = None | Some Int
let show None     = "nothing"
let show (Some n) = "just ${n}"
"${show None}, ${show (Some 42)}"|}
    "nothing, just 42";
  ok "wildcard catch-all"
    {|let label 1 = "one"
let label 2 = "two"
let label _ = "other"
"${label 1}, ${label 2}, ${label 99}"|}
    "one, two, other"

(* ── Environment variables ───────────────────────────────────────────────── *)

let test_envvar () =
  let home = Sys.getenv "HOME" in
  ok "basic"           "$HOME"                    home;
  ok "in let"          "let d = $HOME; d"         home;
  ok "concatenation"   {|$HOME ++ "/bin"|}        (home ^ "/bin");
  ok "interpolation"   {|"home: ${$HOME}"|}       ("home: " ^ home);
  ok "string shorthand" {|"home: $HOME"|}         ("home: " ^ home);
  err "unset var"      "$WAND_UNSET_XYZ_99999"

(* ── Type annotations ────────────────────────────────────────────────────── *)

let test_annot () =
  ok "value annot"      "let x : Int = 42; x"              "42";
  ok "fn return annot"  "let double x : Int = x * 2; double 3" "6";
  err "annot mismatch"  "let x : Bool = 42; x"

(* ── Errors ──────────────────────────────────────────────────────────────── *)

let test_errors () =
  err "unbound in start" "x";
  err "unbound in let"   "let x = y; x"

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
      Alcotest.test_case "type annotations"    `Quick test_annot;
    ];
    "errors", [
      Alcotest.test_case "runtime errors" `Quick test_errors;
    ];
  ]
