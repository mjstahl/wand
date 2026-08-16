open Wand

(* wand has no training-data presence, so a model writing it drifts toward
   the languages it knows: OCaml, Haskell, Python, Ruby, bash. Each
   predictable intrusion must produce an error that names the wand
   correction -- a generic "syntax error at line N" leaves the
   edit-typecheck loop circling. These tests lock in the message text. *)

let contains msg needle =
  let n = String.length needle and m = String.length msg in
  let rec go i = i + n <= m && (String.sub msg i n = needle || go (i + 1)) in
  go 0

let expect_error label src needle =
  match Runner.run_string src with
  | Ok v ->
    Alcotest.failf "%s: expected an error mentioning %S, got value %s"
      label needle v
  | Error msg ->
    if not (contains msg needle) then
      Alcotest.failf "%s: error does not name the correction %S:\n%s"
        label needle msg

let ok label src =
  match Runner.run_string src with
  | Ok _ -> ()
  | Error msg -> Alcotest.failf "%s: expected success, got: %s" label msg

(* ── OCaml ────────────────────────────────────────────────────────────────── *)

let test_ocaml_cons () =
  expect_error "h :: t"
    "let f l = match l with | h :: t -> h | [] -> 0"
    "'::' is OCaml's cons; in wand it is a single ':'"

let test_ocaml_assignment () =
  expect_error "x := 3" "x := 3"
    "':=' is OCaml's assignment, and wand has no mutation"

let test_ocaml_let_rec () =
  expect_error "top-level let rec"
    "let rec f n = if n == 0 then 1 else n * f (n - 1)\nf 3"
    "'let rec' is OCaml; a wand let is already recursive";
  expect_error "let rec inside an expression"
    "let g () = let rec f n = n in f 1\ng ()"
    "'let rec' is OCaml; a wand let is already recursive"

let test_ocaml_fun_is_accepted () =
  (* `fun` is close enough to be read as `fn` rather than refused. *)
  ok "fun aliases fn" "let f = fun x -> x + 1\nf 1"

let test_ocaml_variant_of () =
  expect_error "Circle of Int"
    "type Shape = Circle of Int"
    "a wand constructor takes its payload directly: 'Circle Int'"

let test_ocaml_try_with () =
  expect_error "try ... with cases"
    "try 1 / 0 with _ -> 0"
    "'try ... with' is OCaml; wand's try takes no cases";
  (* The idiom the check must not catch: an unparenthesized try as a
     match scrutinee, where the `with` belongs to the match. *)
  ok "match try ... with"
    "let safe thunk = match try thunk () with | Ok v -> v | Error _ -> 0\n\
     safe (fn () -> 7)"

let test_ocaml_unbound_names () =
  expect_error "ref" "let r = ref 3"
    "wand has no mutation; let binds a new name instead";
  expect_error "raise" "raise \"boom\""
    "errors are values in wand";
  expect_error "print_endline" "print_endline \"hi\""
    "printing is println"

(* ── Haskell ──────────────────────────────────────────────────────────────── *)

let test_haskell_lambda () =
  expect_error "backslash lambda" "let f = \\x -> x + 1"
    "a wand lambda is 'fn x -> ...'"

let test_haskell_cons_pattern () =
  expect_error "(x : xs) in a match"
    "let f l = match l with | (x : xs) -> x"
    "a wand cons pattern is written in square brackets: [x : xs]";
  expect_error "(x : xs) as a parameter"
    "let head (x : xs) = x"
    "a wand cons pattern is written in square brackets: [x : xs]"

(* ── Python ───────────────────────────────────────────────────────────────── *)

let test_python_keywords () =
  expect_error "and" "true and false" "the boolean operator is '&&'";
  expect_error "or" "true or false" "the boolean operator is '||'";
  expect_error "not" "not true" "boolean not is '!'"

let test_python_unbound_names () =
  expect_error "lambda" "let f = lambda\nf" "a lambda is 'fn x -> ...'";
  expect_error "len" "len [1, 2]" "List.length and String.length";
  expect_error "null" "let x = null\nx" "absence is None"

(* ── Comments ─────────────────────────────────────────────────────────────── *)

let test_c_comment () =
  expect_error "// comment" "1 // one"
    "'//' is a C-family comment; wand comments are '-- ...'"

let test_hash_comment () =
  expect_error "# comment" "1 # one"
    "'#' starts a comment in bash and Python; wand comments are '-- ...'"

(* ── String interpolation ─────────────────────────────────────────────────── *)

let test_bash_interpolation () =
  expect_error "${x}" "let x = 1\n\"v: ${x}\""
    "interpolation is %{...} now, not ${...}"

let test_ruby_interpolation () =
  expect_error "#{x}" "let x = 1\n\"v: #{x}\""
    "#{...} is Ruby; interpolation is %{...} in wand";
  ok "escaped literal #{" "\"v: \\#{x}\""

let test_backtick_literal_percent_brace () =
  (* A `...` string cannot hold a literal %{ -- the error must say where
     to go instead, because generated shell/template text will hit it. *)
  expect_error "literal %{ in backticks" "`literal %{ text`"
    "use an ordinary \"...\" string and write \\%{"

(* ── Still-legal neighbours ───────────────────────────────────────────────── *)

(* Every drift check sits next to syntax that must keep working. *)
let test_neighbours_still_parse () =
  ok "cons expression" "1 : [2, 3]";
  ok "port literal" "let p = :8080\np";
  ok "division" "10 / 2";
  ok "annotated binding" "let f x : Int = x + 1\nf 1";
  ok "literal ${ escaped" "\"cost: \\${x}\"";
  ok "shell text keeps $" "\"$HOME and $(date) survive as written\""

let () =
  Alcotest.run "drift" [
    "ocaml", [
      Alcotest.test_case "cons"        `Quick test_ocaml_cons;
      Alcotest.test_case "assignment"  `Quick test_ocaml_assignment;
      Alcotest.test_case "let rec"     `Quick test_ocaml_let_rec;
      Alcotest.test_case "fun"         `Quick test_ocaml_fun_is_accepted;
      Alcotest.test_case "variant of"  `Quick test_ocaml_variant_of;
      Alcotest.test_case "try with"    `Quick test_ocaml_try_with;
      Alcotest.test_case "names"       `Quick test_ocaml_unbound_names;
    ];
    "haskell", [
      Alcotest.test_case "lambda"       `Quick test_haskell_lambda;
      Alcotest.test_case "cons pattern" `Quick test_haskell_cons_pattern;
    ];
    "python", [
      Alcotest.test_case "keywords" `Quick test_python_keywords;
      Alcotest.test_case "names"    `Quick test_python_unbound_names;
    ];
    "comments", [
      Alcotest.test_case "c family" `Quick test_c_comment;
      Alcotest.test_case "hash"     `Quick test_hash_comment;
    ];
    "interpolation", [
      Alcotest.test_case "bash"          `Quick test_bash_interpolation;
      Alcotest.test_case "ruby"          `Quick test_ruby_interpolation;
      Alcotest.test_case "backtick %{"   `Quick test_backtick_literal_percent_brace;
    ];
    "neighbours", [
      Alcotest.test_case "still parse" `Quick test_neighbours_still_parse;
    ];
  ]
