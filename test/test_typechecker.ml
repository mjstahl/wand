open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

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

(* ── Dot access is checked field access ──────────────────────────────────── *)

(* `p.x` on a named type is verified against the type's fields. Key presence
   in a Map is a runtime question, so dot access on a Map is rejected and
   lookup goes through Map.get / Map.get! instead. *)

let test_map_dot_access_rejected () =
  err_contains "dot access on a Map"
    "let m = [x = 1, y = 2] in m.x"
    "cannot use dot access on a Map"

let test_named_field_access_checked () =
  ok "field access on a named type resolves"
    {|type P = P(x: Int, y: Int)
let p = P(x = 1, y = 2) in p.x|}
    "1";
  err_contains "unknown field on a named type"
    {|type P = P(x: Int, y: Int)
let p = P(x = 1, y = 2) in p.z|}
    "has no field 'z'"

let test_map_patterns_still_work () =
  ok "map pattern binds a key"
    {|let m = [x = 1, y = 2] in
match m with
| [x = a] -> a|}
    "1"

(* ── Named-field types are built and matched by name ─────────────────────── *)

(* Positional forms on a named-field type reorder silently when two fields
   share a type, so they are rejected. Constructors without named fields are
   positional by nature and unaffected. *)

let point = {|type P = P(x: Int, y: Int)|}

let test_positional_construction_rejected () =
  err_contains "positional construction of a named-field type"
    (point ^ "\nlet p = P (1, 2) in p.x")
    "has named fields"

let test_tuple_destructuring_rejected () =
  err_contains "tuple destructuring of a named-field type"
    (point ^ "\nlet p = P(x = 1, y = 2) in\nlet (a, b) = p in a + b")
    "cannot destructure 'P' with tuple syntax";
  err_contains "single-field paren destructuring"
    {|type C = C(r: Int)
let c = C(r = 7) in
let (v) = c in v|}
    "cannot destructure 'C' with tuple syntax"

let test_named_forms_survive () =
  ok "named construction and named pattern"
    (point ^ "\nmatch P(x = 1, y = 2) with | P(x = a, y = b) -> a + b")
    "3"

let test_positional_constructors_unaffected () =
  ok "constructor without named fields stays positional"
    {|type Shape = Circle Float | Square Float
match Circle 3.0 with | Circle r -> r | Square s -> s|}
    "3";
  ok "tuple destructuring of an actual tuple"
    "let (a, b) = (1, 2) in a + b"
    "3"

(* ── Multi-equation definitions ──────────────────────────────────────────── *)

(* Equations are tried in source order, so an equation an earlier one already
   answers for can never fire. In a hand-written match an unreachable arm can
   be deliberate; a dead equation never is, since nothing at the definition
   site hints that an earlier line covered it. *)

let test_unreachable_equation_rejected () =
  err_contains "catch-all before a specific equation"
    "let f _ = 0\nlet f 1 = 1\nf 1"
    "equation 2 for 'f' is unreachable";
  err_contains "duplicate equation"
    "let b n = 2\nlet b n = 99\nb 0"
    "unreachable";
  err_contains "unreachable across several parameters"
    "let g _ _ = 2\nlet g 0 0 = 1\ng 0 0"
    "equation 2 for 'g' is unreachable"

let test_equation_messages_speak_in_equations () =
  err_contains "non-exhaustive equations name the function"
    "let f 0 = 0\nlet f 1 = 1\nf 2"
    "the equations for 'f' do not cover every case";
  (* A match the author wrote keeps the match phrasing. *)
  err_contains "hand-written match keeps its own wording"
    "match 3 with\n| 0 -> \"z\""
    "non-exhaustive match"

let test_valid_equation_groups_accepted () =
  ok "ordered equations dispatch in source order"
    "let fib 0 = 0\nlet fib 1 = 1\nlet fib n = fib (n-1) + fib (n-2)\nfib 10"
    "55";
  ok "list equations"
    "let sum [] = 0\nlet sum [h : t] = h + sum t\nsum [1,2,3]"
    "6";
  (* An unreachable arm in a hand-written match stays legal. *)
  ok "hand-written match may have a deliberate dead arm"
    "match 3 with\n| _ -> \"a\"\n| 1 -> \"b\""
    "a"


(* ── Inference, ported from the wand-level types_test suite ──────────────── *)

(* These were written in wand against a Types module that let a script
   typecheck source strings at runtime. Nothing but this suite ever wanted
   that, and testing inference through the interpreter meant a failure could
   come from either. They now call the checker directly. *)

let type_of_expr src =
  match Lexer.tokenize src |> Parser.parse_expr |> Typechecker.infer_expr with
  | Ok t -> Ok (Typechecker.string_of_typ t)
  | Error e -> Error e
  | exception (Lexer.LexError e | Parser.ParseError e) -> Error e

let type_of_program src =
  match Lexer.tokenize src |> Parser.parse_program |> Typechecker.infer_program with
  | Ok t -> Ok (Typechecker.string_of_typ t)
  | Error e -> Error e
  | exception (Lexer.LexError e | Parser.ParseError e) -> Error e

let expr_is label src expected =
  match type_of_expr src with
  | Ok t -> Alcotest.(check string) label expected t
  | Error e -> Alcotest.failf "%s: expected %s, got error: %s" label expected e

let prog_is label src expected =
  match type_of_program src with
  | Ok t -> Alcotest.(check string) label expected t
  | Error e -> Alcotest.failf "%s: expected %s, got error: %s" label expected e

let rejects label src =
  match type_of_expr src with
  | Error _ -> ()
  | Ok t -> Alcotest.failf "%s: expected a type error, got %s" label t


let test_primitive_literals () =
  expr_is "int" "42" "Int";
  expr_is "float" "3.14" "Float";
  expr_is "string" "\"hello\"" "String";
  expr_is "true" "true" "Bool";
  expr_is "false" "false" "Bool";
  expr_is "unit" "()" "Unit"

let test_domain_literals () =
  expr_is "path" "/etc/foo" "Path";
  expr_is "date" "2024-01-15" "Date";
  expr_is "time" "14:30:00" "Time";
  expr_is "duration" "5min" "Duration";
  expr_is "url" "https://example.com" "Url";
  expr_is "ipv4" "192.168.1.1" "IPv4";
  expr_is "cidr" "10.0.0.0/24" "CIDR";
  expr_is "port" ":8080" "Port";
  expr_is "version" "1.2.3" "Version";
  expr_is "size" "10MB" "Size"

let test_variables () =
  expr_is "int var" "let x = 1 in x" "Int";
  expr_is "bool var" "let x = true in x" "Bool";
  expr_is "string var" "let x = \"hi\" in x" "String";
  expr_is "shadow" "let x = 1 in let x = true in x" "Bool"

let test_arithmetic___comparison () =
  expr_is "add" "1 + 2" "Int";
  expr_is "sub" "1 - 2" "Int";
  expr_is "mul" "2 * 3" "Int";
  expr_is "div" "6 / 2" "Int";
  expr_is "eq int" "1 == 1" "Bool";
  expr_is "eq string" "\"a\" == \"b\"" "Bool";
  expr_is "neq" "1 != 2" "Bool";
  expr_is "lt" "1 < 2" "Bool";
  expr_is "gt" "1 > 2" "Bool";
  expr_is "lte" "1 <= 2" "Bool";
  expr_is "gte" "1 >= 2" "Bool";
  expr_is "and" "true && false" "Bool";
  expr_is "or" "true || false" "Bool";
  expr_is "not" "!true" "Bool";
  expr_is "neg" "-1" "Int"

let test_if () =
  expr_is "int branches" "if true then 1 else 0" "Int";
  expr_is "string branches" "if true then \"a\" else \"b\"" "String";
  expr_is "nested" "if true then if false then 1 else 2 else 3" "Int"

let test_let () =
  expr_is "body arith" "let x = 1 in x + 1" "Int";
  expr_is "fn in let" "let f = fn x -> x + 1 in f 5" "Int";
  expr_is "fn shorthand" "let f x = x + 1 in f 5" "Int";
  expr_is "recursive" "let fact n = if n <= 0 then 1 else n * fact (n - 1) in fact 5" "Int";
  expr_is "poly id" "let id x = x in id 1" "Int"

let test_functions () =
  expr_is "identity" "fn x -> x" "'a -> 'a";
  expr_is "add one" "fn x -> x + 1" "Int -> Int";
  expr_is "const" "fn x -> fn y -> x" "'a -> 'b -> 'a";
  expr_is "flip" "fn x -> fn y -> y" "'a -> 'b -> 'b";
  (* Applying a function performs whatever that function performs, so the
     row variable links the argument to the result. *)
  expr_is "compose" "fn f -> fn x -> f x" "('a -> 'b ! 'e) -> 'a -> 'b ! 'e"

let test_application () =
  expr_is "int result" "(fn x -> x + 1) 5" "Int";
  expr_is "bool result" "(fn x -> x) true" "Bool";
  expr_is "two args" "(fn x -> fn y -> x) 1 true" "Int"

let test_let_polymorphism () =
  expr_is "id int" "let id = fn x -> x in id 1" "Int";
  expr_is "id bool" "let id = fn x -> x in id true" "Bool";
  expr_is "id string" "let id = fn x -> x in id \"hi\"" "String"

let test_tuples () =
  expr_is "pair" "(1, true)" "(Int, Bool)";
  expr_is "triple" "(1, 2, 3)" "(Int, Int, Int)";
  expr_is "nested" "((1, 2), true)" "((Int, Int), Bool)"

let test_lists () =
  expr_is "empty" "[]" "List 'a";
  expr_is "ints" "[1, 2, 3]" "List Int";
  expr_is "strings" "[\"a\", \"b\"]" "List String"

let test_match () =
  expr_is "bool scrutinee" "match true with\n| true -> 1\n| false -> 0" "Int";
  expr_is "wildcard arm" "match 1 with\n| 1 -> true\n| _ -> false" "Bool";
  expr_is "guard" "fn n -> match n with\n| x when x > 0 -> true\n| _ -> false" "Int -> Bool"

let test_pipeline () =
  expr_is "pipeline" "1 |> fn x -> x + 1" "Int";
  expr_is "double pipe" "1 |> fn x -> x + 1 |> fn x -> x * 2" "Int"

let test_type_errors () =
  rejects "add bool" "1 + true";
  rejects "if not bool" "if 1 then 2 else 3";
  rejects "branch mismatch" "if true then 1 else true";
  rejects "apply non-fn" "1 2";
  rejects "list mismatch" "[1, true]"

let test_program_level_inference__enum_types () =
  prog_is "nullary" "type Color = Red | Green; Red" "Color";
  prog_is "second" "type Color = Red | Green; Green" "Color"

let test_program_level_inference__payload_types () =
  prog_is "single arg" "type Wrap = Wrap Int; Wrap 42" "Wrap";
  prog_is "two args" "type Pair = Pair Int Int; Pair 3 4" "Pair"

let test_program_level_inference__match_on_constructors () =
  prog_is "nullary arms" "type Color = Red | Green\nlet f c = match c with\n| Red   -> 1\n| Green -> 2\nf Red" "Int";
  prog_is "payload arm" "type Wrap = Wrap Int\nlet unwrap w = match w with\n| Wrap n -> n\nunwrap (Wrap 42)" "Int"

let test_program_level_inference__named_field_typedef () =
  prog_is "field access" "type Point (x : Int, y : Int)\nlet p = Point (x = 1, y = 2)\np.x" "Int";
  prog_is "second field" "type Point (x : Int, y : Int)\nlet p = Point (x = 1, y = 2)\np.y" "Int"

let test_program_level_inference__constructor_errors () =
  rejects "unknown ctor" "Bogus";
  rejects "wrong arg type" "type Wrap = Wrap Int; Wrap true"

let test_type_annotations () =
  prog_is "value annot" "let x : Int = 42; x" "Int";
  prog_is "fn return annot" "let double x : Int = x * 2; double 3" "Int";
  rejects "annot mismatch" "let x : Bool = 42"

let test_type_annotation_syntax () =
  prog_is "tuple annot" "let x : (Int, Int) = (1, 2); x" "(Int, Int)";
  prog_is "list annot matches inference" "let xs : List Int = [1, 2, 3]; xs" "List Int";
  prog_is "map annot matches inference" "let m : Map Int = [x = 1, y = 2]; m" "Map Int";
  prog_is "result annot matches inference" "let r : Result String Int = Ok 1; r" "Result String Int";
  prog_is "function annot" "let f : Int -> Int = fn x -> x + 1; f 1" "Int";
  prog_is "left-nested function annot" "let g : (Int -> Int) -> Int = fn f -> f 1; g (fn x -> x + 1)" "Int";
  prog_is "list of tuples annot" "let xs : List (Int, Int) = [(1, 2)]; xs" "List (Int, Int)";
  rejects "unsupported generic head" "let x : Option Int = 1"

let test_constructor_field_grouping () =
  prog_is "single field grouped application" "type Wrap = Wrap (List Int); let w = Wrap [1, 2, 3]; w" "Wrap";
  prog_is "single field grouped tuple" "type Pair = Pair (Int, Int); let p = Pair (1, 2); p" "Pair";
  prog_is "named field with colon" "type Point (x : Int, y : Int)\nlet p = Point (x = 1, y = 2)\np.x" "Int"


(* ── Rejections gathered from the wand-level suites ──────────────────────── *)

(* Each of these was asserted in wand via Types.fails?, beside a behavioral
   test of the same feature. They are type errors, so they belong with the
   checker; the behavioral tests stay where they are. *)

let type_of_program_with_imports src =
  try
    let prog = Lexer.tokenize src |> Parser.parse_program in
    let cache = Hashtbl.create 8 in
    let loading = ref [] in
    let base_dir = Sys.getcwd () in
    let (imp, _) = Runner.load_imports_for ~base_dir ~cache ~loading prog in
    match Typechecker.infer_program_env ~init_tenv:imp.tenv ~init_env:imp.type_env prog with
    | Ok _ -> Ok ()
    | Error e -> Error e
  with
  | Lexer.LexError e | Parser.ParseError e | Typechecker.TypeError e -> Error e
  | Failure e -> Error e

let rejects_program label src =
  match type_of_program_with_imports src with
  | Error _ -> ()
  | Ok () -> Alcotest.failf "%s: expected a type error" label

let test_contract_clauses_must_be_bool () =
  rejects_program "requires must be Bool" "let f x =\n  requires x + 1\n  x\nf 1";
  rejects_program "ensures must be Bool" "let f x =\n  ensures result + 1\n  x\nf 1"

let test_unbound_names () =
  rejects "unbound variable" "x";
  rejects_program "unbound in a let" "let x = y; x";
  rejects_program "unbound argument" "println undefined_var"

let test_generic_type_errors () =
  (match type_of_program "type Foo 'a = Bar 'b; 1" with
   | Error e ->
     Alcotest.(check bool) "names the undeclared variable and its type" true
       (contains e "is not declared as a parameter")
   | Ok t -> Alcotest.failf "expected an error, got %s" t);
  rejects_program "wrong type at use site"
    "type Option 'a = None | Some 'a\nlet f (x : Int) = x\nf (Some 1)";
  rejects_program "constructor arity mismatch"
    "type Box 'a = Box 'a\nmatch Box 1 with | Box a b -> a"

let test_builtin_argument_types () =
  rejects_program "read_file! on a non-string" "import FS\nFS.read_file! 42";
  rejects_program "write_file! on a non-string path" "import FS\nFS.write_file! 42 \"content\"";
  rejects_program "print_err on a non-string" "import IO\nIO.print_err 42";
  rejects "exit on a non-int" "exit \"bye\""

let test_glob_is_not_a_path () =
  rejects_program "a Path where a Glob belongs" "import FS\nFS.glob /etc .";
  rejects_program "a String where a Glob belongs" "import FS\nFS.glob \"*.wand\" ."

let test_operator_type_errors () =
  rejects "int ++ string" "1 ++ \"a\"";
  rejects "string ++ int" "\"a\" ++ 1";
  rejects "bad expression inside interpolation" "\"${1 + true}\"";
  rejects "cons onto a non-list" "1 : 2";
  rejects "cons of the wrong element type" "1 : [\"a\", \"b\"]"

let test_constructor_and_pattern_errors () =
  rejects "unknown constructor" "Bogus";
  rejects_program "wrong constructor arity" "type Wrap = Wrap Int; Wrap 1 2";
  rejects_program "unknown field in a pattern"
    "type Point (x : Int, y : Int)\nlet p = Point (x = 1, y = 2)\n\
     let sum = match p with | Point (x = a, z = b) -> a + b\nsum";
  rejects_program "and-bound member must be a function"
    "let f n = n\nand g = 5\nf 1";
  rejects_program "annotation contradicts the value" "let x : Bool = 42; x";
  rejects "non-exhaustive match" "match 5 with\n| 1 -> true";
  rejects "applying a non-function" "1 2"

(* The checker suggests a near-miss name rather than only reporting the
   unbound one. *)
let test_did_you_mean_suggestions () =
  let suggests src needle =
    match type_of_program src with
    | Error m ->
      if not (contains m needle) then
        Alcotest.failf "expected %S in error, got: %s" needle m
    | Ok t -> Alcotest.failf "expected an error, got %s" t
  in
  suggests "let name = 1; naem" "name";
  suggests "type Color = Red | Green; Gren" "Green";
  suggests "type Point (x : Int, y : Int)\nlet p = Point (x = 1, y = 2)\np.xy" "x";
  (* Including a mistyped keyword, which fails in the parser rather than
     the checker. *)
  suggests "lte x = 1; x" "let"


(* Errors carry the source position of the construct that caused them, which
   is what makes a failed typecheck actionable rather than merely correct. *)
let test_error_locations () =
  let says src needle =
    match type_of_program src with
    | Error m ->
      if not (contains m needle) then
        Alcotest.failf "expected %S in error for %S, got: %s" needle src m
    | Ok t -> Alcotest.failf "expected an error for %S, got %s" src t
  in
  says "List.map (fn x -> x + 1) [1, 2, 3]" "forget to import the standard library List";
  (* Parse errors. *)
  says "let x = 1\n= bad\nx" "2:";
  says "let x = 1\n= bad\nx" ":1";
  (* Type errors. *)
  says "let y = 1 + true\ny" "1:";
  says "let y = 1 + true\ny" ":9";
  says "let x = 1\nlet y = x + true\ny" "2:";
  says "let x =\n  if true then\n    1 + true\n  else 0\nx" "3:";
  says "let f n =\n  match n with\n  | 0 -> 1 + true\n  | _ -> 0\nf 1" "3:";
  (* Exhaustiveness is a type error, so it is located like the rest. *)
  let exhaustive = "type C = A | B\nlet x = A\nlet y = match x with | B -> 1\ny" in
  says exhaustive "3:";
  says exhaustive ":9"


(* ── What handlers discharge ─────────────────────────────────────────────── *)

(* Resolves imports, so a case can use a stdlib function. *)
let type_of label src =
  match
    (try
       let prog = Lexer.tokenize src |> Parser.parse_program in
       let cache = Hashtbl.create 8 in
       let loading = ref [] in
       let (imp, _) =
         Runner.load_imports_for ~base_dir:(Sys.getcwd ()) ~cache ~loading prog in
       (match Typechecker.infer_program_full_with_own
                ~init_tenv:imp.tenv ~init_env:imp.type_env prog with
        | Ok (_, _, t, _) -> Ok (Typechecker.string_of_typ t)
        | Error e -> Error e)
     with
     | Lexer.LexError e | Parser.ParseError e | Typechecker.TypeError e -> Error e
     | Failure e -> Error e)
  with
  | Ok t -> t
  | Error e -> Alcotest.failf "%s: %s" label e

(* A handler removes the effect of the operation it intercepts. *)
let test_handler_discharges_its_operation () =
  Alcotest.(check string) "Shell is gone once process_run is handled"
    "Unit -> 'a ! {Raise}"
    (type_of "handled shell"
       "fn () -> handle $(git push) with\n| Shell!run _ k -> k \"ok\"")

(* The Raise that survives above is $()'s own check on a non-zero exit, which
   a handler supplying the output does prevent -- but a row records which
   effects occurred, not which operation caused them, and the same Raise is
   indistinguishable from one a raising call inside the body performed.
   Discharging it would therefore drop that one too, so it stays. Keeping an
   effect that cannot happen is imprecise; dropping one that can is a lie. *)
let test_handler_keeps_raises_it_cannot_account_for () =
  Alcotest.(check string) "a raise from elsewhere in the body survives"
    "Map 'a -> 'b ! {Raise}"
    (type_of "raise from elsewhere"
       "import Map\nfn m -> handle\n  let x = Map.get! \"k\" m in\n  $(echo hi)\nwith\n| Shell!run _ k -> k \"ok\"")

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Typechecker" [
    "effects", [
      Alcotest.test_case "handler discharges its operation" `Quick test_handler_discharges_its_operation;
      Alcotest.test_case "handler keeps other raises"       `Quick test_handler_keeps_raises_it_cannot_account_for;
    ];
    "rejections", [
      Alcotest.test_case "contract clauses"    `Quick test_contract_clauses_must_be_bool;
      Alcotest.test_case "unbound names"       `Quick test_unbound_names;
      Alcotest.test_case "generics"            `Quick test_generic_type_errors;
      Alcotest.test_case "builtin arguments"   `Quick test_builtin_argument_types;
      Alcotest.test_case "glob vs path"        `Quick test_glob_is_not_a_path;
      Alcotest.test_case "operators"           `Quick test_operator_type_errors;
      Alcotest.test_case "constructors"        `Quick test_constructor_and_pattern_errors;
      Alcotest.test_case "did-you-mean"        `Quick test_did_you_mean_suggestions;
      Alcotest.test_case "error locations"     `Quick test_error_locations;
    ];
    "inference", [
      Alcotest.test_case "Primitive literals" `Quick test_primitive_literals;
      Alcotest.test_case "Domain literals" `Quick test_domain_literals;
      Alcotest.test_case "Variables" `Quick test_variables;
      Alcotest.test_case "Arithmetic & comparison" `Quick test_arithmetic___comparison;
      Alcotest.test_case "If" `Quick test_if;
      Alcotest.test_case "Let" `Quick test_let;
      Alcotest.test_case "Functions" `Quick test_functions;
      Alcotest.test_case "Application" `Quick test_application;
      Alcotest.test_case "Let polymorphism" `Quick test_let_polymorphism;
      Alcotest.test_case "Tuples" `Quick test_tuples;
      Alcotest.test_case "Lists" `Quick test_lists;
      Alcotest.test_case "Match" `Quick test_match;
      Alcotest.test_case "Pipeline" `Quick test_pipeline;
      Alcotest.test_case "Type errors" `Quick test_type_errors;
      Alcotest.test_case "Program-level inference: enum types" `Quick test_program_level_inference__enum_types;
      Alcotest.test_case "Program-level inference: payload types" `Quick test_program_level_inference__payload_types;
      Alcotest.test_case "Program-level inference: match on constructors" `Quick test_program_level_inference__match_on_constructors;
      Alcotest.test_case "Program-level inference: named field typedef" `Quick test_program_level_inference__named_field_typedef;
      Alcotest.test_case "Program-level inference: constructor errors" `Quick test_program_level_inference__constructor_errors;
      Alcotest.test_case "Type annotations" `Quick test_type_annotations;
      Alcotest.test_case "Type annotation syntax" `Quick test_type_annotation_syntax;
      Alcotest.test_case "Constructor field grouping" `Quick test_constructor_field_grouping;
    ];
    "field access", [
      Alcotest.test_case "map dot access rejected" `Quick test_map_dot_access_rejected;
      Alcotest.test_case "named fields checked"    `Quick test_named_field_access_checked;
      Alcotest.test_case "map patterns unaffected" `Quick test_map_patterns_still_work;
    ];
    "multi-equation", [
      Alcotest.test_case "unreachable rejected"  `Quick test_unreachable_equation_rejected;
      Alcotest.test_case "messages use equations" `Quick test_equation_messages_speak_in_equations;
      Alcotest.test_case "valid groups accepted" `Quick test_valid_equation_groups_accepted;
    ];
    "named-field types", [
      Alcotest.test_case "positional construction rejected" `Quick test_positional_construction_rejected;
      Alcotest.test_case "tuple destructuring rejected"     `Quick test_tuple_destructuring_rejected;
      Alcotest.test_case "named forms survive"              `Quick test_named_forms_survive;
      Alcotest.test_case "positional ctors unaffected"      `Quick test_positional_constructors_unaffected;
    ];
  ]
