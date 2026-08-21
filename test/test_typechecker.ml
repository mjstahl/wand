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
    "let m = {x = 1, y = 2} in m.x"
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

(* Inferring what a recursive function performs means already knowing it: the
   body calls the function being inferred. The constraint is a fixed point,
   and rejecting it meant a recursive function could carry no effect of its
   own -- only ones handed to it as a parameter, which is why `List.each`
   typechecked and a loop that printed did not. *)

let test_recursion_may_perform_effects () =
  ok "a recursive function that prints"
    {|import IO
let go n = if n == 0 then 0 else let () = IO.println "x" in go (n - 1)
go 0|}
    "0";
  err_contains "and the effect reaches the signature"
    {|uses {}
import IO
let go n = if n == 0 then 0 else let () = IO.println "x" in go (n - 1)
go 0|}
    "performs IO";
  ok "an effect on the base case counts too"
    {|import IO
let go n = if n == 0 then let () = IO.println "x" in 0 else go (n - 1)
go 0|}
    "0";
  err_contains "mutual recursion carries it across the group"
    {|uses {}
import IO
let a n = if n == 0 then 0 else b (n - 1)
and b n = let () = IO.println "x" in a (n - 1)
a 0|}
    "performs IO";
  (* The over-approximating direction stays: a pure recursion gains nothing,
     and an effect taken as a parameter stays a variable. *)
  ok "pure recursion is still pure"
    {|uses {}
let count n = if n == 0 then 0 else count (n - 1)
count 3|}
    "0"

(* A type name that is not declared anywhere used to become an opaque type of
   its own, so a misspelling was accepted and only surfaced -- if at all -- as
   a unification failure at some later use. *)

let test_unknown_type_names_rejected () =
  err_contains "a field naming a type that does not exist"
    {|type Meta = Meta(name: String)
type Pod = Pod(metadata: Meta, status: Status)
1|}
    "unknown type 'Status'";
  err_contains "and it says which declaration invented it"
    {|type Pod = Pod(status: Status)
1|}
    "in field 'status' of 'Pod'";
  err_contains "a misspelling is offered the name it missed"
    {|type Meta = Meta(name: String)
type P = P(m: Mata)
1|}
    "did you mean 'Meta'";
  err_contains "a positional field too"
    {|type S = Circle Radius | Square Int
1|}
    "unknown type 'Radius'";
  err_contains "an annotation, which carries its own location"
    "let f x : Itn = x
2"
    "unknown type 'Itn'";
  (* Declaration order is not the point: types are collected before any is
     read, and that stays true. *)
  ok "a field may name a type declared further down"
    {|type A = A(b: B)
type B = B(n: Int)
(A(b = B(n = 7))).b.n|}
    "7";
  ok "generic parameters are not type names"
    {|type Box 'a = Box 'a
type W = W(b: Box Int)
let w = W(b = Box 1) in 1|}
    "1";
  ok "builtin types are known without an import"
    {|type W = W(l: List Int, p: Path, d: Duration)
1|}
    "1";
  (* A module's type needs the import that brings the module in, the same as
     its functions do. Unimported, it was silently a type of its own. *)
  ok "an imported type is known"
    {|import Option
type W = W(o: Option String)
1|}
    "1";
  err_contains "the same type unimported"
    {|type W = W(o: Option String)
1|}
    "unknown type 'Option'"

(* A value of a multi-constructor type is one of its constructors, and which
   one is not known at the access. A field only some constructors carry used
   to typecheck and fail when the value turned out to be one of the others. *)

let test_field_must_be_on_every_constructor () =
  ok "a field every constructor carries reads fine"
    {|type T = A(x: Int, u: Int) | B(x: Int, w: Int)
(B(x = 7, w = 9)).x|}
    "7";
  err_contains "a field only some constructors carry"
    {|type T = A(x: Int) | B(y: Int)
let v = B(y = 2) in v.x|}
    "is not on every constructor";
  err_contains "the same field at two types"
    {|type T = A(x: Int) | B(x: String)
let v = A(x = 1) in v.x|}
    "depends on the constructor";
  err_contains "a field no constructor has"
    {|type T = A(x: Int) | B(x: Int)
let v = A(x = 1) in v.zz|}
    "has no field 'zz'"

(* A named constructor's arity is as known as a positional one's, so leaving
   a field out is a type error rather than something the evaluator finds. *)

let test_construction_needs_every_field () =
  err_contains "one field left out"
    {|type M = M(a: Int, b: Int)
M(a = 1)|}
    "is missing field 'b'";
  err_contains "several left out"
    {|type M = M(a: Int, b: Int, c: Int)
M(b = 1)|}
    "is missing fields 'a', 'c'";
  ok "every field given, in any order"
    {|type M = M(a: Int, b: Int)
let m = M(b = 2, a = 1) in m.a|}
    "1";
  (* Patterns still bind a subset -- naming one field is how you read it. *)
  ok "a pattern may name fewer fields than the type has"
    {|type M = M(a: Int, b: Int)
match M(a = 1, b = 2) with
| M(a = n) -> n|}
    "1"

let test_map_patterns_still_work () =
  ok "map pattern binds a key"
    {|let m = {x = 1, y = 2} in
match m with
| {x = a} -> a|}
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

(* ── A tuple pattern says the value is a tuple ───────────────────────────── *)

(* A tuple pattern against a type not yet known used to bind its parts and
   commit to nothing, so `fn (a, b) -> a` was inferred as `'a -> 'b` and
   accepted anything -- the mismatch surfaced at run time as a non-exhaustive
   match, in a language whose whole claim is that it would not. It now says
   what it destructures, like every other pattern. *)

let test_tuple_pattern_types_its_scrutinee () =
  ok "a tuple pattern is a tuple"
    "let f p = match p with | (a, b) -> a + b in f (1, 2)"
    "3";
  err_contains "a non-tuple passed to a tuple pattern"
    "let f p = match p with | (a, b) -> a in f 3"
    "expected";
  err_contains "a non-tuple passed to a tuple parameter"
    "let f (a, b) = a in f 3"
    "expected";
  err_contains "the wrong width"
    "let f p = match p with | (a, b) -> a in f (1, 2, 3)"
    "expected"

(* ── Effect payloads in handler cases ───────────────────────────────────── *)

(* A handler case binds what an operation carries and resumes it with what it
   supplies. Both used to be inferred as fresh variables, so a case could read
   a path as a String and only find out when it ran -- unchecked, in the one
   construct whose whole job is standing at a boundary. *)
let test_handler_payloads_are_typed () =
  err_contains "a path is not a String"
    {|import FS
handle FS.write_file! /tmp/x "hi" with
| FS!write_file (path, _) k -> path ++ "!" ++ k ()|}
    "expected String, got Path";
  err_contains "resuming a read with the wrong type"
    "import FS\nhandle FS.read_file! /tmp/x with | FS!read_file _ k -> k 42"
    "expected String, got Int";
  err_contains "a payload bound at the wrong shape"
    "import FS\nhandle FS.delete! /tmp/x with | FS!delete (a, b) k -> k ()"
    "expected Path, got";
  ok "and a case that agrees with the operation still works"
    {|import FS
import Path
handle FS.read_file! /tmp/nonexistent with
| FS!read_file p k -> k "mocked: %{Path.to_string p}"|}
    "mocked: /tmp/nonexistent";
  (* The `Env` operations carried no types at all until a port hit it:
     `Env.get` is `try get!`, so the operation supplies the `String` its
     raising builtin returns, and a case resuming with an `Int` made
     `Env.get` answer `Some(42)`. *)
  err_contains "resuming an environment read with the wrong type"
    "import Env\nhandle Env.get \"HOME\" with | Env!get _ k -> k 42"
    "expected String, got Int";
  err_contains "and asking for the user as a Path"
    "import Env\nhandle Env.user () with | Env!user _ k -> k /tmp"
    "expected String, got Path";
  ok "a case that agrees with an environment read still works"
    {|import Env
handle Env.get! "ANYTHING" with
| Env!get name k -> k "mocked: %{name}"|}
    "mocked: ANYTHING";
  (* `Shell!run` carries either a command or a command and its stdin, so it
     has no single payload type and its cases stay open. *)
  ok "an operation with two payload shapes is left open"
    {|handle $(echo hi) with
| Shell!run cmd k -> "mocked"|}
    "mocked"

(* ── One-armed if ────────────────────────────────────────────────────────── *)

(* `if c then e` is `if c then e else ()`: one conditional, not a second
   construct. The branch must therefore be Unit, and saying only "expected
   Unit, got Int" would leave the reader looking for the Unit. *)
let test_one_armed_if () =
  ok "does the thing"      "if 1 > 0 then println \"a\"" "()";
  ok "or does nothing"     "if 1 > 2 then println \"a\"" "()";
  err_contains "a branch that is not Unit says why"
    "if true then 1"
    "an `if` with no `else` does nothing when the condition is false";
  (* An `else` that was written keeps the ordinary message. *)
  err_contains "a written else is a plain mismatch"
    "if true then 1 else \"x\""
    "expected Int, got String"

(* ── Derived decoders ────────────────────────────────────────────────────── *)

(* A type that is not a single-constructor record has no shape a decoder
   could read. Naming one has to say which of those it is, since "no field
   'decoder'" would send the reader looking for a field. *)
let test_underivable_types_say_why () =
  err_contains "several constructors"
    "type Shape = Circle Int | Rect Int Int\nlet d = Shape.decoder"
    "type 'Shape' has no derived decoder: it has more than one constructor";
  (* A constructor's positional payload, which is a different thing from the
     positional *construction* of a named-field type that the language does
     not have -- `Wrap Int` is fine to write, it just has nothing to read a
     document by. *)
  err_contains "a positional payload"
    "type Wrap = Wrap Int\nlet d = Wrap.decoder"
    "its payload has no field names";
  err_contains "a type variable the type does not declare"
    "type Bad = Bad(v: 'a)\nlet d = Bad.decoder"
    "not declared as a parameter";
  (* A `Map` field became derivable when `Decode.dict` landed; a tuple did
     not, and cannot -- a document is read by name, and a tuple has none. *)
  err_contains "a field with no decoder"
    "type T = T(t: (Int, Int))\nlet d = T.decoder"
    "field 't' cannot be read";
  ok "a Map field is read by Decode.dict"
    {|type M (m: Map Int)
match M.decoder with
| _ -> "ok"|}
    "ok";
  err_contains "an enum"
    "type Color = Red | Green\nlet d = Color.decoder"
    "more than one constructor"

let test_derived_decoder_has_the_type () =
  ok "a derived decoder is a Decoder of its type"
    {|type Pod (name: String, restarts: Int)
let d = Pod.decoder
match Pod.decoder with
| _ -> "ok"|}
    "ok"

(* ── Multi-equation definitions ──────────────────────────────────────────── *)

(* Equations are tried in source order, so an equation an earlier one already
   answers for can never fire. In a hand-written match an unreachable case can
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
  (* An unreachable case in a hand-written match stays legal. *)
  ok "hand-written match may have a deliberate dead case"
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
  | exception ((Lexer.LexError _ | Parser.ParseError _) as e) ->
    Error (Runner.legacy_of_exn e)

let type_of_program src =
  match Lexer.tokenize src |> Parser.parse_program |> Typechecker.infer_program with
  | Ok t -> Ok (Typechecker.string_of_typ t)
  | Error e -> Error e
  | exception ((Lexer.LexError _ | Parser.ParseError _) as e) ->
    Error (Runner.legacy_of_exn e)

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
     effect variable links the argument to the result. *)
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
  expr_is "wildcard case" "match 1 with\n| 1 -> true\n| _ -> false" "Bool";
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
  prog_is "nullary cases" "type Color = Red | Green\nlet f c = match c with\n| Red   -> 1\n| Green -> 2\nf Red" "Int";
  prog_is "payload case" "type Wrap = Wrap Int\nlet unwrap w = match w with\n| Wrap n -> n\nunwrap (Wrap 42)" "Int"

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
  prog_is "map annot matches inference" "let m : Map Int = {x = 1, y = 2}; m" "Map Int";
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
  | (Lexer.LexError _ | Parser.ParseError _ | Typechecker.TypeError _
    | Typechecker.TypeErrorAt _) as e -> Error (Runner.legacy_of_exn e)
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

(* `file*.txt` is not multiplication: `*.txt` lexes as a glob, so it reads as
   applying `file` to it. "unbound variable 'file'" sends the reader after a
   binding nobody meant to write, so the error says what was meant instead. *)
let test_bare_word_glob () =
  (match type_of_expr "file*.txt" with
   | Ok t -> Alcotest.failf "expected a type error, got %s" t
   | Error e ->
     Alcotest.(check string) "says what to write, and stops"
       "'file*.txt' should be written as './file*.txt'"
       (Util.strip_loc_prefix e));
  (* A bound function applied to a glob is ordinary code and stays that way. *)
  (match type_of_program_with_imports "import FS
let _ = FS.glob *.wand" with
   | Ok () -> ()
   | Error e -> Alcotest.failf "FS.glob *.wand should typecheck, got: %s" e)

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
  rejects "bad expression inside interpolation" "\"%{1 + true}\"";
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

(* A constructor's payload is what follows it in parentheses, so a nullary
   one written beside a call swallows that call: `f None (g x)` is
   `f (None (g x))`, and the type error was about an application nobody
   wrote. The parser cannot tell -- it reads no arity, on purpose -- so the
   checker says what to write. *)
let test_a_nullary_constructor_swallows_the_next_argument () =
  let says label src needle =
    match type_of_program src with
    | Error m ->
      if not (contains m needle) then
        Alcotest.failf "%s: expected %S in error, got: %s" label needle m
    | Ok t -> Alcotest.failf "%s: expected an error, got %s" label t
  in
  (match type_of_program_with_imports "import Option
let f a b = a
f None (f 1 2)" with
   | Ok () -> Alcotest.fail "the stdlib one: expected an error"
   | Error m ->
     if not (contains m "write `(None)` to pass the constructor on its own") then
       Alcotest.failf "the stdlib one: got: %s" m);
  says "and one declared here"
    "type Color = Red | Green
let f a b = a
f Red (f 1 2)"
    "'Red' takes no arguments";
  (* Called the way a function is called, which has a shorter answer. *)
  says "a nullary constructor applied to unit"
    "type Color = Red | Green
let r = Red ()
r"
    "write `Red`, with nothing after it";
  (* A constructor that does take a payload is untouched. *)
  (match type_of_program "type Wrap = Wrap Int
let w = Wrap (1 + 2)
w" with
   | Ok _ -> ()
   | Error m -> Alcotest.failf "a payload constructor was rejected: %s" m)

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
        | Error (_, e, _) -> Error e)
     with
     | (Lexer.LexError _ | Parser.ParseError _ | Typechecker.TypeError _
       | Typechecker.TypeErrorAt _) as e -> Error (Runner.legacy_of_exn e)
     | Failure e -> Error e)
  with
  | Ok t -> t
  | Error e -> Alcotest.failf "%s: %s" label e

(* A handler removes the effect of the operation it intercepts. *)
(* A written type may carry effects. The printer emitted four shapes the
   grammar could not read back, so a signature `wand t` reported was not one
   you could paste into an annotation. *)
let test_written_effects_round_trip () =
  let annotated ty body expected =
    Alcotest.(check string) ty expected
      (type_of ty (Printf.sprintf "let f : %s = %s in f" ty body))
  in
  annotated "Unit -> String ! {Raise, Shell}" "fn () -> $(git status)"
    "Unit -> String ! {Raise, Shell}";
  annotated "Unit -> String ! {Shell | 'e}" "fn () -> $(git status)"
    "Unit -> String ! {Raise, Shell}";
  annotated "'a -> 'a ! 'e" "fn x -> x" "'a -> 'a";
  annotated "Int -> Int" "fn n -> n" "Int -> Int"

(* A pattern that can fail makes the binding raise, and the type has to say
   so -- nothing else records it, since the raise comes from the binding
   rather than from any call inside the body.

   What decides it is whether the value could be another constructor, not
   whether the fields were written by name. Reading a named pattern as
   irrefutable on the strength of its spelling alone let
   `let area (Circle (radius = r)) = r` over `Circle | Square` claim to be
   total, and reading a positional one as refutable regardless made
   `let unwrap (Wrap n) = n` claim a risk that a single-constructor type
   cannot carry. *)
let test_a_failable_pattern_raises () =
  let shapes = "type Shape = Circle (radius : Int) | Square (side : Int)\n" in
  let one = "type Wrap = Wrap Int\ntype Boxed (item : Int)\n" in
  Alcotest.(check string) "a named pattern over two constructors"
    "Shape -> Int ! {Raise}"
    (type_of "named, several constructors"
       (shapes ^ "let f (Circle (radius = r)) = r in f"));
  Alcotest.(check string) "a positional one over two constructors"
    "Result 'b 'a -> 'a ! {Raise}"
    (type_of "positional, several constructors" "let f (Ok v) = v in f");
  Alcotest.(check string) "a positional pattern over one constructor"
    "Wrap -> Int"
    (type_of "positional, one constructor" (one ^ "let f (Wrap n) = n in f"));
  Alcotest.(check string) "a named pattern over one constructor"
    "Boxed -> Int"
    (type_of "named, one constructor" (one ^ "let f (Boxed (item = i)) = i in f"));
  (* Whatever the outer constructor, a field pattern that can fail is still
     a way for the binding to fail. *)
  Alcotest.(check string) "a failable pattern inside a named field"
    "Holder -> Int ! {Raise}"
    (type_of "nested" ("type Holder (items : List Int)\n"
                       ^ "let f (Holder (items = [a])) = a in f"));
  (* A binding is not different from a parameter: both fail where they
     stand. *)
  Alcotest.(check string) "a let binding that can fail"
    "Result 'b 'a -> 'a ! {Raise}"
    (type_of "let binding" "let f r = let Ok v = r in v in f");
  Alcotest.(check string) "and one that cannot"
    "Wrap -> Int"
    (type_of "irrefutable let binding" (one ^ "let f w = let Wrap n = w in n in f"))

(* A written type variable is a promise to whoever reads the signature, and
   unification alone cannot keep it: a variable unifies with Int as readily
   as with anything else, so an annotation could claim a generality the body
   does not have. The effects half of this was closed when written effects
   arrived; this is the types half. *)
let test_written_type_vars_are_checked () =
  let fails label src needle =
    match Runner.run_string src with
    | Ok v -> Alcotest.failf "%s: expected a type error, got %s" label v
    | Error msg ->
      if not (Lint.contains msg needle) then
        Alcotest.failf "%s: expected %S in: %s" label needle msg
  in
  let passes label src =
    match Runner.run_string src with
    | Ok _ -> ()
    | Error msg -> Alcotest.failf "%s: %s" label msg
  in
  fails "a variable the body decided"
    "let f : 'a -> 'a = fn x -> x + 1\nf 1"
    "stands for any type";
  fails "two variables the body tied together"
    "let g : 'a -> 'b = fn x -> x\ng 1"
    "separate types";
  fails "a variable standing for a concrete value"
    "let n : 'a = 5\nn"
    "stands for any type";
  passes "the identity really is polymorphic"
    "let ident : 'a -> 'a = fn x -> x\nident 1";
  passes "two variables the body keeps apart"
    "let pair : 'a -> 'b -> ('a, 'b) = fn x -> fn y -> (x, y)\npair 1 \"s\"";
  (* Narrower than the body is not a claim about anything. *)
  passes "a concrete annotation over a polymorphic body"
    "let at_int : Int -> Int = fn x -> x\nat_int 1";
  (* `Num` is not a written variable: each one is a fresh numeric type that
     use sites decide. *)
  passes "Num still works"
    "let twice : Num -> Num = fn x -> x + x\ntwice 2"

(* A type on a parameter is what lets a function read a field off one. Dot
   access needs a named type, and a definition is generalized before any call
   site is seen, so the type has to come from the definition. There was
   nowhere to write it. *)
let test_a_parameter_can_carry_a_type () =
  let pod = "type Pod (name : String, phase : String)\n" in
  Alcotest.(check string) "a field is readable now" "Pod -> String"
    (type_of "annotated parameter"
       (pod ^ "let describe (p: Pod) = p.name in describe"));
  Alcotest.(check string) "and so is a field of a field"
    "Outer -> Int"
    (type_of "two deep"
       ("type Inner (n : Int)\ntype Outer (i : Inner)\n"
        ^ "let f (o: Outer) = o.i.n in f"));
  Alcotest.(check string) "the return annotation composes" "Pod -> String"
    (type_of "both annotations"
       (pod ^ "let describe (p: Pod) : String = p.name in describe"));
  (* The annotation constrains; it does not replace inference. *)
  Alcotest.(check string) "a narrower annotation is accepted" "Int -> Int"
    (type_of "narrowing" "let f (x: Int) = x in f");
  (* And an annotation is not a pattern that can fail. *)
  Alcotest.(check string) "it adds no Raise" "Pod -> String"
    (type_of "no raise" (pod ^ "let f = fn (p: Pod) -> p.name in f"))

let test_a_parameter_type_is_checked () =
  let fails label src needle =
    match Runner.run_string src with
    | Ok v -> Alcotest.failf "%s: expected a type error, got %s" label v
    | Error msg ->
      if not (Lint.contains msg needle) then
        Alcotest.failf "%s: expected %S in: %s" label needle msg
  in
  fails "the body contradicts the annotation"
    "type Pod (name : String)\nlet f (p: Pod) = p ++ \"x\"\nf"
    "expected";
  fails "the call contradicts the annotation"
    "type Pod (name : String)\nlet f (p: Pod) = p.name\nf 3"
    "expected Pod, got Int";
  (* Each annotation resolves its own names, so a variable in one would not
     be the variable in the next. Refused rather than quietly weaker. *)
  fails "a type variable is refused"
    "let f (x: 'a) = x\nf 1"
    "not shared with the other patterns"

(* `<`, `>`, `<=` and `>=` take an `Ord`: a type wand knows how to order.
   Before the constraint they were `'a -> 'a -> Bool`, and the evaluator
   raised for anything but Int, Float and String -- so `100MB < 1GB`
   typechecked and failed during the run, and two functions could be
   compared at all. *)
let test_ordering_is_a_constraint () =
  let fails label src needle =
    match Runner.run_string src with
    | Ok v -> Alcotest.failf "%s: expected a type error, got %s" label v
    | Error msg ->
      if not (Lint.contains msg needle) then
        Alcotest.failf "%s: expected %S in: %s" label needle msg
  in
  let ok label src expected =
    match Runner.run_string src with
    | Ok v -> Alcotest.(check string) label expected v
    | Error msg -> Alcotest.failf "%s: %s" label msg
  in
  ok "a duration" "30s < 5min" "true";
  ok "a date" "2024-01-15 < 2024-02-01" "true";
  ok "an instant, offsets applied"
    "2024-01-15T20:00:00+05:30 == 2024-01-15T14:30:00Z" "true";
  (* A type outside the set is refused where it is written, and the message
     names it rather than listing the set, which grows. *)
  fails "a regex" "r/a/ < r/b/" "Regex is not ordered";
  fails "a list" "[1] < [2]" "List Int is not ordered";
  fails "two functions" "(fn x -> x) < (fn y -> y)" "is not ordered";
  ok "a size" "100MB < 1GB" "true";
  ok "a version, by number and not by text" "1.10.0 > 1.9.0" "true";
  ok "an address, by its number" "10.0.0.9 < 10.0.0.10" "true";
  ok "a port" ":80 < :443" "true";
  (* Ord composes as Num does: a function that only compares stays
     polymorphic over every ordered type. *)
  Alcotest.(check string) "a comparison stays polymorphic" "Ord -> Ord -> Ord"
    (type_of "later" "let later a b = if a < b then b else a in later");
  (* The constraints nest, so a variable carrying two of them keeps the
     narrower: Num inside Add inside Ord. *)
  Alcotest.(check string) "Add wins over Ord" "Add -> Add -> Bool"
    (type_of "add and compare" "let f a b = a + b > a in f");
  Alcotest.(check string) "Num wins over Add" "Num -> Num -> Num -> Num"
    (type_of "add and multiply" "let f a b c = a + b * c in f")

(* `+` and `-` take one constraint wider than `*` and `/`: the two
   quantities add to their own type, and multiplying them would not. *)
let test_add_constraint () =
  let ok label src expected =
    match Runner.run_string src with
    | Ok v -> Alcotest.(check string) label expected v
    | Error msg -> Alcotest.failf "%s: %s" label msg
  in
  let fails label src needle =
    match Runner.run_string src with
    | Ok v -> Alcotest.failf "%s: expected a type error, got %s" label v
    | Error msg ->
      if not (Lint.contains msg needle) then
        Alcotest.failf "%s: expected %S in: %s" label needle msg
  in
  ok "two sizes" "100MB + 4KB" "100004000B";
  ok "two durations" "1h + 30min" "1h30m";
  (* Neither type goes below zero. *)
  ok "a size floors at zero" "4KB - 100MB" "0B";
  ok "a duration floors at zero" "5s - 10s" "0s";
  fails "a path" "/tmp + /var" "Path does not add";
  fails "a string" {|"a" + "b"|} "strings concatenate with '++'";
  fails "a size times a size" "100MB * 2" "* and / work on Int and Float";
  Alcotest.(check string) "a sum stays polymorphic" "Add -> Add -> Add"
    (type_of "sum" "let sum a b = a + b in sum");
  Alcotest.(check string) "and the annotation for it round-trips" "Size"
    (type_of "annotated" "let sum : Add -> Add -> Add = fn a b -> a + b in sum 1MB 2MB")

(* Written effects are checked, not assumed: an annotation cannot quietly
   narrow what a function does. This is what makes writing them safe to
   allow at all. *)
let test_written_effects_are_checked () =
  err_contains "declaring fewer effects than the body performs"
    "let f : Unit -> String ! {Shell} = fn () -> $(git status) in f"
    "the type allows {Shell}, but the body performs Raise";
  err_contains "declaring none at all"
    "let f : Unit -> String ! {} = fn () -> $(git status) in f"
    "but the body performs Raise, Shell";
  err_contains "an effect that does not exist"
    "let f : Unit -> Unit ! {Netwrk} = fn () -> () in f"
    "unknown effect 'Netwrk'"

(* The reason the grammar earns its place, and it only shows across a module
   boundary. Inside one file the implementation supplies the link: writing
   `R (fn thunk -> thunk ())` makes inference tie the thunk's effects to the
   call's, and a field variable nobody wrote is monomorphic, so the link
   survives to the match.

   A constructor reached through an import has no implementation to look at
   -- its scheme is rebuilt from the declaration -- so the link exists only
   if the declaration states it. `Testing`'s `raises` is the case: without
   `'e` on both sides, `t.raises (fn () -> $(cmd))` typechecked in a file
   whose manifest was `uses {}` and ran the command. *)
let test_written_effects_relate_a_field_across_a_module () =
  match type_of_program_with_imports
          "uses {}\nlet {test} = import Test\n\
           test \"t\" (fn t -> t.raises (fn () -> $(git status)))" with
  | Ok () ->
    Alcotest.fail "the thunk's effects should reach the caller's manifest"
  | Error m ->
    if not (contains m "performs Shell") then
      Alcotest.failf "expected Shell to surface, got: %s" m

(* A function stored in a constructor field carries its effects with it. The
   field's effects are not written down -- the grammar has no place for them
   -- so they are inferred at construction, and the match that takes the
   field back out has to see the same ones. It did not: the constructor's
   scheme quantified them although its result type (`Action`, not
   `Action 'e`) does not mention them, so construction picked Shell and the
   match picked nothing, and this typechecked under `uses {}` and ran the
   command. *)
let launders label src =
  match type_of_program_with_imports ("uses {}\n" ^ src) with
  | Ok () -> Alcotest.failf "%s: the effect was laundered -- uses {} accepted" label
  | Error m ->
    if not (contains m "performs Shell") then
      Alcotest.failf "%s: expected the Shell to surface, got: %s" label m

let test_constructor_field_keeps_its_effects () =
  launders "a positional field, matched"
    "type Action = Action (Unit -> String)\n\
     let a = Action (fn () -> $(echo hi))\n\
     let fire x = match x with\n| Action f -> f ()\n\
     let go = fire a";
  launders "a named field, read by dot access"
    "type Box = Box(run: (Unit -> String))\n\
     let b = Box(run = fn () -> $(echo hi))\n\
     let go = (b.run) ()";
  launders "a named field, matched"
    "type Box = Box(run: (Unit -> String))\n\
     let b = Box(run = fn () -> $(echo hi))\n\
     let fire x = match x with\n| Box(run = f) -> f ()\n\
     let go = fire b";
  (* A field behind a type parameter always worked, because the parameter is
     in the result type and so generalises soundly. It has to keep working. *)
  launders "a field behind a type parameter"
    "type Box 'a = Box 'a\n\
     let b = Box (fn () -> $(echo hi))\n\
     let fire x = match x with\n| Box f -> f ()\n\
     let go = fire b"

(* Constructing performs nothing, so a constructor's own arrows are pure.
   When they carried an effect variable instead -- shared, since these are no
   longer generalised -- one `Some` used where a raise was possible made every
   `Some` in the program raise, and pure code was told to rename itself. *)
let test_constructing_performs_nothing () =
  Alcotest.(check string) "Some carries no effects of its own"
    "'a -> Option 'a"
    (type_of "pure construction" "import Option\nfn n -> Some n");
  (* The shape that caught it: a pure function building an Option, in a file
     that also raises. With the constructor's arrows sharing one variable the
     Raise reached this one too, and the linter told a pure function to
     rename itself `tally!`. *)
  Alcotest.(check string) "and does not collect them from elsewhere in the file"
    "'a -> Option 'a"
    (type_of "pure beside a raise"
       "import Option\nimport List\n\
        let boom xs = List.head! xs\n\
        fn s -> match None with\n| Some e -> Some e\n| None -> Some s")

(* An effect is discharged when every operation carrying it is handled --
   here Proc, which carries exactly one, so one case covers it and nothing
   in the body can still end the process. *)
let test_handler_covering_every_operation_discharges_it () =
  Alcotest.(check string) "Proc is gone once Proc!exit is handled"
    "Unit -> 'a"
    (type_of "handled exit"
       "import Proc\nfn () -> handle (Proc.exit 1) with\n| Proc!exit _ k -> k 0")

(* The security-critical half. A case intercepts one operation, but Shell
   carries four, and a signature is written in effects rather than
   operations. Handling `Shell!run` leaves `Shell!run_quiet`, `Shell!capture`
   and `Shell!exit_code` reaching the default handler and running for real,
   so Shell has to stay.

   Dropping it here is what let a file whose manifest was `uses {IO}` run any
   command it liked: one handler case for an operation the body never
   performed erased the whole effect, and `wand t --strict` said nothing. *)
let test_partial_handler_keeps_the_effect () =
  Alcotest.(check string) "one of Shell's four operations does not discharge it"
    "Unit -> String ! {Raise, Shell}"
    (type_of "partly handled shell"
       "fn () -> handle $(git push) with\n| Shell!run _ k -> k \"ok\"");
  Alcotest.(check string) "one of FS.Write's ten does not discharge it"
    "Path -> Unit ! {FS.Write, Raise}"
    (type_of "partly handled writes"
       "import FS\nfn p -> handle (FS.write_file! p \"x\") with\n\
        | FS!write_file _ k -> k ()")

(* A case naming an operation that does not exist was accepted in silence,
   and since nothing intercepted it the real effect ran -- so a mistyped mock
   became a live effect. *)
let test_handler_rejects_an_unknown_operation () =
  match type_of_program_with_imports
          "import FS\nlet f p = handle (FS.read_file! p) with\n\
           | FS!read_fil _ k -> k \"fake\"\nf" with
  | Ok () -> Alcotest.fail "expected a case for a nonexistent operation to be rejected"
  | Error m ->
    if not (contains m "no effect operation named 'FS!read_fil'") then
      Alcotest.failf "expected the operation to be named, got: %s" m;
    if not (contains m "FS!read_file") then
      Alcotest.failf "expected a suggestion, got: %s" m

(* The Raise that survives below is $()'s own check on a non-zero exit, which
   a handler supplying the output does prevent -- but an effect set records
   which effects occurred, not which operation caused them, and the same
   Raise is indistinguishable from one a raising call inside the body
   performed. Discharging it would therefore drop that one too, so it stays.
   Keeping an effect that cannot happen is imprecise; dropping one that can
   is a lie -- the same reason a partial handler keeps its effect above. *)
let test_handler_keeps_raises_it_cannot_account_for () =
  Alcotest.(check string) "a raise from elsewhere in the body survives"
    "Map 'a -> String ! {Raise, Shell}"
    (type_of "raise from elsewhere"
       "import Map\nfn m -> handle\n  let x = Map.get! \"k\" m in\n  $(echo hi)\nwith\n| Shell!run _ k -> k \"ok\"")


(* ── Manifests ───────────────────────────────────────────────────────────── *)

(* A manifest states what a file may do. It is checked against everything the
   file defines rather than what running it performs, since a function that
   shells out does so whenever something calls it. *)

let manifest_error label src needle =
  match type_of_program_with_imports src with
  | Ok () -> Alcotest.failf "%s: expected the manifest to be rejected" label
  | Error m ->
    if not (contains m needle) then
      Alcotest.failf "%s: expected %S in error, got: %s" label needle m

let test_manifest_too_narrow () =
  manifest_error "a shell call the manifest omits"
    "uses {FS.Write}\nlet publish () = $(rsync -a . host:/srv)\npublish"
    "which the manifest does not allow";
  (* The suggestion is the narrowed form when every command word is
     literal: the binaries were read from the text, so name them. *)
  manifest_error "and it says what to write instead"
    "uses {FS.Write}\nlet publish () = $(rsync -a . host:/srv)\npublish"
    "uses {Shell(rsync)}"

let test_manifest_shell_binaries () =
  let ok label src =
    match type_of_program_with_imports src with
    | Ok () -> ()
    | Error m -> Alcotest.failf "%s: rejected: %s" label m
  in
  ok "an allowed word"
    "uses {Shell(git)}\nlet b () = $(git status)\nb";
  manifest_error "a word the list omits"
    "uses {Shell(git)}\nlet b () = $(curl x)\nb"
    "runs 'curl', which Shell(git) does not allow";
  manifest_error "and the fix names the extended list, in canonical order"
    "uses {Shell(git)}\nlet b () = $(curl x)\nb"
    "uses {Shell(curl, git)}";
  manifest_error "every pipeline stage is a position"
    "uses {Shell(git)}\nlet b () = $(git log | wc -l)\nb"
    "runs 'wc'";
  manifest_error "control flow cannot be bounded"
    "uses {Shell(git)}\nlet b () = $(for f in x; do git add $f; done)\nb"
    "shell control flow";
  (* Wrappers are the thing you allow: wand does not peel `env` to find
     the "real" command, because every peeling rule is an escape hatch. *)
  ok "the wrapper is the checked word"
    "uses {Shell(env)}\nlet b () = $(env X=1 curl x)\nb";
  ok "a bare entry admits a path-qualified word"
    "uses {Shell(git)}\nlet b () = $(/usr/bin/git status)\nb";
  manifest_error "a slash entry stays exact"
    "uses {Shell(\"/opt/bin/git\")}\nlet b () = $(/usr/bin/git status)\nb"
    "does not allow";
  (* An interpolated command word is legal here -- it is the spawn-time
     check's case -- and the narrowed suggestion is withheld. *)
  ok "a dynamic word typechecks under a narrowed manifest"
    "uses {Shell(git)}\nlet b c = $(%!{c} status)\nb";
  manifest_error "a dynamic site makes the suggestion fall back to bare Shell"
    "uses {}\nlet b c = $(%!{c} status)\nb \"git\""
    "uses {Shell}"

let test_manifest_names_the_binding () =
  manifest_error "the binding that introduced the effect"
    "uses {}\nlet quiet x = x + 1\nlet noisy () = $(echo hi)\nnoisy"
    "'noisy'"

let test_manifest_accepts_an_exact_declaration () =
  match type_of_program_with_imports
          "uses {Shell}\nlet publish () = $(rsync -a . host:/srv)\npublish" with
  | Ok () -> ()
  | Error m -> Alcotest.failf "expected it to pass: %s" m

(* Arithmetic is polymorphic over Int and Float through a Num-constrained
   variable: no defaulting, no implicit mixing, `%` stays Int. `+` and `-`
   carry the wider `Add`, which a `Num` annotation narrows again. *)
let test_num_arithmetic () =
  let ok label src =
    match type_of_program_with_imports src with
    | Ok () -> ()
    | Error m -> Alcotest.failf "%s: rejected: %s" label m
  in
  ok "float arithmetic" "let area r = 3.14 * r * r\narea 2.5";
  ok "a Num function serves both types"
    "let double x = x + x\nlet a = double 2\nlet b = double 1.5\n(a, b)";
  ok "a Num annotation round-trips"
    "let double : Num -> Num = fn x -> x + x\n(double 2, double 1.5)";
  manifest_error "no implicit mixing"
    "1.5 + 1"
    "Float.of_int and Float.round convert between them";
  manifest_error "modulo stays Int"
    "1.5 % 2.0"
    "Int and Float do not mix";
  manifest_error "Num rejects non-numbers"
    "let f x = x * x\nf true"
    "expected a number, got Bool";
  manifest_error "strings are pointed at ++"
    "\"a\" + \"b\""
    "strings concatenate with '++', not '+'";
  (* `+` is one constraint wider, so what it refuses it refuses by name. *)
  manifest_error "Add rejects what does not add"
    "let f x = x + x\nf true"
    "Bool does not add"

let test_no_manifest_is_unconstrained () =
  match type_of_program_with_imports
          "let publish () = $(rsync -a . host:/srv)\npublish" with
  | Ok () -> ()
  | Error m -> Alcotest.failf "expected it to pass: %s" m

(* Raise is control flow, already visible in a `!` name, so it never has to
   be declared. *)
let test_manifest_ignores_raise () =
  match type_of_program_with_imports
          "uses {}\nimport Map\nlet get m = Map.get! \"k\" m\nget" with
  | Ok () -> ()
  | Error m -> Alcotest.failf "Raise should not need declaring: %s" m

let test_manifest_rejects_unknown_labels () =
  manifest_error "a label that is not an effect"
    "uses {Bogus}\nlet x = 1\nx"
    "is not an effect"

(* What using a member commits a file's manifest to -- the query the
   editor's auto-import tier asks before extending `uses {...}`
   (LSP.md §2.1). Asked of the schemes an import binds, exactly as the
   server will ask it. *)
let test_manifest_labels_of_member () =
  let env =
    let sess = Runner.make_session () in
    match Runner.run_session sess "import FS\nimport List" with
    | Ok (s, _) -> s.Runner.s_type_env
    | Error m -> Alcotest.failf "imports failed: %s" m
  in
  let member ns name =
    match List.assoc_opt ns env with
    | Some (Typechecker.Namespace members) ->
      (match List.assoc_opt name members with
       | Some s -> s
       | None -> Alcotest.failf "%s has no member %s" ns name)
    | _ -> Alcotest.failf "no namespace %s" ns
  in
  let labels s =
    Typechecker.manifest_labels_of_scheme s
    |> Effect_set.EffSet.elements |> List.map Effect_set.name_of
  in
  Alcotest.(check (list string)) "write_file! implies FS.Write, not Raise"
    ["FS.Write"] (labels (member "FS" "write_file!"));
  Alcotest.(check (list string)) "read_file implies FS.Read"
    ["FS.Read"] (labels (member "FS" "read_file"));
  Alcotest.(check (list string)) "a polymorphic effect set commits to nothing"
    [] (labels (member "List" "map"));
  Alcotest.(check (list string)) "a namespace itself commits to nothing"
    [] (labels (List.assoc "FS" env))


(* ── Parentheses group a tuple ───────────────────────────────────────────── *)

(* `Ctor (a, b)` used to mean two arguments or one tuple depending on whether
   the constructor's type was declared in the same file, since that is all
   the parser could see. Now it always means one tuple, and several arguments
   are written by juxtaposition. *)

let test_imported_constructor_takes_a_tuple () =
  match type_of_program_with_imports
          "import Option\nmatch Some (1, 2) with | Some (a, b) -> a + b | None -> 0" with
  | Ok () -> ()
  | Error m -> Alcotest.failf "a tuple payload should work when imported: %s" m

let test_local_constructor_takes_a_tuple () =
  ok "declared in the same file"
    "type P = P (Int, Int)\nmatch P (1, 2) with | P (a, b) -> a + b"
    "3"

let test_several_arguments_are_juxtaposed () =
  ok "juxtaposition"
    "type R = R Int Int\nmatch R 3 4 with | R a b -> a + b"
    "7"

(* The natural mistake now has one meaning, so the error says what to write. *)
let test_arity_hint () =
  err_contains "a tuple where arguments were meant"
    "type R = R Int Int\nR (3, 4)"
    "write `R a1 a2`";
  (* A named-field type has a different right answer, and keeps its own. *)
  err_contains "named fields are unaffected"
    "type P = P(x: Int, y: Int)\nP (1, 2)"
    "has named fields"

(* ── Suite ───────────────────────────────────────────────────────────────── *)

(* A generic type takes one decoder per parameter, in the order it declares
   them, and gives back a decoder for the applied type. *)
let test_generic_derivation () =
  prog_is "one parameter"
    "type Box 'a (v: 'a)\nBox.decoder"
    "Decoder 'a -> Decoder (Box 'a)";
  prog_is "two, in order"
    "type Pair 'a 'b (left: 'a, right: 'b)\nPair.decoder"
    "Decoder 'a -> Decoder 'b -> Decoder (Pair 'a 'b)";
  prog_is "and the encoder takes encoders"
    "type Box 'a (v: 'a)\nBox.encoder"
    "('a -> JSON) -> Box 'a -> JSON";
  (* Constructing one keeps its arguments, which is what makes the pair fit
     together: `Box(v = 3)` is a `Box Int`, exactly as `Box 3` is. *)
  prog_is "named construction applies the parameters"
    "type Box 'a (v: 'a)\nBox(v = 3)"
    "Box Int";
  prog_is "and a field of an applied type is the argument"
    "type Box 'a (v: 'a)\nlet b = Box(v = 3)\nb.v"
    "Int"


let () =
  Alcotest.run "Typechecker" [
    "constructor arguments", [
      Alcotest.test_case "imported tuple payload" `Quick test_imported_constructor_takes_a_tuple;
      Alcotest.test_case "local tuple payload"    `Quick test_local_constructor_takes_a_tuple;
      Alcotest.test_case "juxtaposition"          `Quick test_several_arguments_are_juxtaposed;
      Alcotest.test_case "arity hint"             `Quick test_arity_hint;
    ];
    "manifests", [
      Alcotest.test_case "too narrow is an error"  `Quick test_manifest_too_narrow;
      Alcotest.test_case "shell binaries"          `Quick test_manifest_shell_binaries;
      Alcotest.test_case "names the binding"       `Quick test_manifest_names_the_binding;
      Alcotest.test_case "exact passes"            `Quick test_manifest_accepts_an_exact_declaration;
      Alcotest.test_case "absent is unconstrained" `Quick test_no_manifest_is_unconstrained;
      Alcotest.test_case "Raise is not declared"   `Quick test_manifest_ignores_raise;
      Alcotest.test_case "unknown label rejected"  `Quick test_manifest_rejects_unknown_labels;
      Alcotest.test_case "labels of a member"      `Quick test_manifest_labels_of_member;
    ];
    "num", [
      Alcotest.test_case "polymorphic arithmetic" `Quick test_num_arithmetic;
    ];
    "effects", [
      Alcotest.test_case "written effects round-trip"   `Quick test_written_effects_round_trip;
      Alcotest.test_case "written effects are checked"   `Quick test_written_effects_are_checked;
      Alcotest.test_case "written effects relate a field"  `Quick test_written_effects_relate_a_field_across_a_module;
      Alcotest.test_case "constructor field keeps effects" `Quick test_constructor_field_keeps_its_effects;
      Alcotest.test_case "constructing is pure"         `Quick test_constructing_performs_nothing;
      Alcotest.test_case "full coverage discharges"    `Quick test_handler_covering_every_operation_discharges_it;
      Alcotest.test_case "partial handler keeps effect" `Quick test_partial_handler_keeps_the_effect;
      Alcotest.test_case "a failable pattern raises" `Quick test_a_failable_pattern_raises;
      Alcotest.test_case "written type vars are checked" `Quick
        test_written_type_vars_are_checked;
      Alcotest.test_case "a parameter carries a type" `Quick
        test_a_parameter_can_carry_a_type;
      Alcotest.test_case "a parameter type is checked" `Quick
        test_a_parameter_type_is_checked;
      Alcotest.test_case "ordering is a constraint" `Quick
        test_ordering_is_a_constraint;
      Alcotest.test_case "adding is a constraint" `Quick
        test_add_constraint;
      Alcotest.test_case "unknown operation rejected"   `Quick test_handler_rejects_an_unknown_operation;
      Alcotest.test_case "handler keeps other raises"   `Quick test_handler_keeps_raises_it_cannot_account_for;
    ];
    "rejections", [
      Alcotest.test_case "contract clauses"    `Quick test_contract_clauses_must_be_bool;
      Alcotest.test_case "unbound names"       `Quick test_unbound_names;
      Alcotest.test_case "bare-word glob"      `Quick test_bare_word_glob;
      Alcotest.test_case "generics"            `Quick test_generic_type_errors;
      Alcotest.test_case "builtin arguments"   `Quick test_builtin_argument_types;
      Alcotest.test_case "glob vs path"        `Quick test_glob_is_not_a_path;
      Alcotest.test_case "operators"           `Quick test_operator_type_errors;
      Alcotest.test_case "constructors"        `Quick test_constructor_and_pattern_errors;
      Alcotest.test_case "nullary constructor"  `Quick
        test_a_nullary_constructor_swallows_the_next_argument;
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
      Alcotest.test_case "recursion + effects"     `Quick test_recursion_may_perform_effects;
      Alcotest.test_case "unknown type names"      `Quick test_unknown_type_names_rejected;
      Alcotest.test_case "field on every ctor"     `Quick test_field_must_be_on_every_constructor;
      Alcotest.test_case "construction complete"   `Quick test_construction_needs_every_field;
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
      Alcotest.test_case "a tuple pattern types its value"  `Quick test_tuple_pattern_types_its_scrutinee;
    ];
    "handler payloads", [
      Alcotest.test_case "typed by the operation" `Quick test_handler_payloads_are_typed;
    ];
    "one-armed if", [
      Alcotest.test_case "branch must be Unit" `Quick test_one_armed_if;
    ];
    "derived decoders", [
      Alcotest.test_case "underivable types say why" `Quick test_underivable_types_say_why;
      Alcotest.test_case "derived decoder types"     `Quick test_derived_decoder_has_the_type;
      Alcotest.test_case "generic derivation"        `Quick test_generic_derivation;
    ];
  ]
