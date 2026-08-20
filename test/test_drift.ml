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
    "cons is a single ':', not '::'"

let test_ocaml_assignment () =
  expect_error "x := 3" "x := 3"
    "there is no mutation, so there is no ':='"

let test_ocaml_let_rec () =
  expect_error "top-level let rec"
    "let rec f n = if n == 0 then 1 else n * f (n - 1)\nf 3"
    "a let is already recursive -- drop the 'rec'";
  expect_error "let rec inside an expression"
    "let g () = let rec f n = n in f 1\ng ()"
    "a let is already recursive -- drop the 'rec'"

let test_ocaml_fun_is_accepted () =
  (* `fun` is close enough to be read as `fn` rather than refused. *)
  ok "fun aliases fn" "let f = fun x -> x + 1\nf 1"

let test_ocaml_variant_of () =
  expect_error "Circle of Int"
    "type Shape = Circle of Int"
    "a constructor takes its payload directly: 'Circle Int'"

let test_ocaml_try_with () =
  expect_error "try ... with cases"
    "try 1 / 0 with _ -> 0"
    "try takes no cases, so there is no 'try ... with'";
  (* The idiom the check must not catch: an unparenthesized try as a
     match scrutinee, where the `with` belongs to the match. *)
  ok "match try ... with"
    "let safe thunk = match try thunk () with | Ok v -> v | Error _ -> 0\n\
     safe (fn () -> 7)"

let test_ocaml_unbound_names () =
  expect_error "ref" "let r = ref 3"
    "there is no mutation; let binds a new name instead";
  expect_error "raise" "raise \"boom\""
    "errors are values: return an Error";
  expect_error "print_endline" "print_endline \"hi\""
    "printing is println"

(* ── Haskell ──────────────────────────────────────────────────────────────── *)

let test_haskell_lambda () =
  expect_error "backslash lambda" "let f = \\x -> x + 1"
    "a lambda is 'fn x -> ...'"

let test_haskell_cons_pattern () =
  expect_error "(x : xs) in a match"
    "let f l = match l with | (x : xs) -> x"
    "a cons pattern is written in square brackets: [x : xs]";
  expect_error "(x : xs) as a parameter"
    "let head (x : xs) = x"
    "a cons pattern is written in square brackets: [x : xs]"

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
    "or '(* ... *)' -- not '//'"

let test_hash_comment () =
  expect_error "# comment" "1 # one"
    "or '(* ... *)' -- not '# ...'"

(* ── String interpolation ─────────────────────────────────────────────────── *)

let test_bash_interpolation () =
  expect_error "${x}" "let x = 1\n\"v: ${x}\""
    "interpolation is %{...}, not ${...}"

let test_ruby_interpolation () =
  expect_error "#{x}" "let x = 1\n\"v: #{x}\""
    "interpolation is %{...}, not #{...}";
  ok "escaped literal #{" "\"v: \\#{x}\""

let test_backtick_literal_percent_brace () =
  (* A `...` string cannot hold a literal %{ -- the error must say where
     to go instead, because generated shell/template text will hit it. *)
  expect_error "literal %{ in backticks" "`literal %{ text`"
    "use an ordinary \"...\" string and write \\%{"

(* ── Round two: what the cold-model run surfaced ──────────────────────────── *)

let test_string_concat () =
  expect_error "^ concatenation" "\"a\" ^ \"b\""
    "string concatenation is '++', not '^'"

let test_float_operators () =
  expect_error "*." "let a = 1.5\na *. a"
    "operators are not spelled differently for Float -- there is no '*.'";
  expect_error "+." "let a = 1.5\na +. 2.0" "there is no '+.'";
  expect_error "-." "let a = 1.5\na -. 2.0" "there is no '-.'";
  expect_error "/." "let a = 1.5\na /. 2.0" "there is no '/.'"

let test_char_literal () =
  expect_error "char literal" "let c = 'x'"
    "there are no character literals: a one-character string is \"x\""

let test_begin_end () =
  expect_error "begin/end block" "let x = begin 1 end\nx"
    "expressions group with parentheses, not 'begin ... end'"

let test_foreign_members () =
  expect_error "List.iter" "import List\nList.iter (fn x -> x) [1]"
    "use List.each";
  expect_error "String.sub" "import String\nString.sub \"abc\" 0 1"
    "use String.slice";
  expect_error "FS.read_lines" "import FS\nFS.read_lines /tmp/x"
    "FS.read_file! reads the whole file";
  expect_error "int_of_string" "int_of_string \"4\""
    "String.to_int reads an Int out of a String"

let test_discovery_pointers () =
  (* When no correction is known, the error hands over the enumerator --
     the binary is the only documentation a cold reader has. *)
  expect_error "unknown name" "frobnicate 3"
    "'wand v' lists the modules, 'wand v List' one module's members";
  expect_error "unknown member" "import String\nString.frobnicate \"x\""
    "'wand v String' lists its members"

(* ── wand's own past ──────────────────────────────────────────────────────── *)

(* The 0.17 bracket maps. Code that learned wand before the braces landed --
   or a model trained on it -- still writes `[x = 1]`, and the correction has
   to be named the same way any other dialect's is. *)
let test_bracket_maps () =
  expect_error "bracket map literal" "let m = [x = 1]\nm"
    "a map is written in braces -- {k = v}, not [k = v]";
  expect_error "bracket map pattern"
    "let f x = match x with | [k = v] -> v\nf {k = 1}"
    "a map pattern is written in braces -- {k = v}, not [k = v]";
  expect_error "bracket import destructure"
    "let [parse] = import JSON\nparse \"1\""
    "an import is destructured with braces"

(* ── Still-legal neighbours ───────────────────────────────────────────────── *)

(* Every drift check sits next to syntax that must keep working. *)
let test_neighbours_still_parse () =
  ok "cons expression" "1 : [2, 3]";
  ok "port literal" "let p = :8080\np";
  ok "division" "10 / 2";
  ok "annotated binding" "let f x : Int = x + 1\nf 1";
  ok "literal ${ escaped" "\"cost: \\${x}\"";
  ok "shell text keeps $" "\"$HOME and $(date) survive as written\"";
  (* The float-operator and concat checks sit beside real tokens. *)
  ok "globs still lex" "let g = *.wand\ng";
  ok "type variables still lex" "let id x : 'a = x\nid 1";
  ok "subtraction still works" "5 - 2";
  ok "addition still works" "5 + 2";
  (* The bracket-map refusal keys on `ident =` after `[`; a name or an
     equality inside a list is not a map and must stay one. *)
  ok "a list of names" "let x = 1\n[x, 2]";
  ok "equality inside a list" "let x = 1\n[x == 1]"

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
    "round two", [
      Alcotest.test_case "string concat"   `Quick test_string_concat;
      Alcotest.test_case "float operators" `Quick test_float_operators;
      Alcotest.test_case "char literal"    `Quick test_char_literal;
      Alcotest.test_case "begin/end"       `Quick test_begin_end;
      Alcotest.test_case "foreign members" `Quick test_foreign_members;
      Alcotest.test_case "discovery"       `Quick test_discovery_pointers;
    ];
    "interpolation", [
      Alcotest.test_case "bash"          `Quick test_bash_interpolation;
      Alcotest.test_case "ruby"          `Quick test_ruby_interpolation;
      Alcotest.test_case "backtick %{"   `Quick test_backtick_literal_percent_brace;
    ];
    "wand's own past", [
      Alcotest.test_case "bracket maps" `Quick test_bracket_maps;
    ];
    "neighbours", [
      Alcotest.test_case "still parse" `Quick test_neighbours_still_parse;
    ];
  ]
