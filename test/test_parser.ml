open Wand
open Ast

let parse s =
  Lexer.tokenize s |> Parser.parse_expr

let expr = Alcotest.(testable Ast.pp Ast.equal)

let e label input expected =
  Alcotest.(check expr) label expected (parse input)

let parse_program s =
  Lexer.tokenize s |> Parser.parse_program

let refuses label src needle =
  match (try Ok (parse_program src) with Parser.ParseError (_, m) -> Error m) with
  | Ok _ -> Alcotest.failf "%s: expected a parse error" label
  | Error m ->
    if not (Lint.contains m needle) then
      Alcotest.failf "%s: expected %S in: %s" label needle m

(* ── A binding in a block ────────────────────────────────────────────────── *)

(* Inside parentheses a `let` binds for the rest of the block. `;` is what
   ends its right-hand side, exactly as a newline does at the top level of a
   file, so a block and a file read the same way.

   Before this, `(let x = 1; x + 2)` parsed -- and bound nothing. The
   binding took `Unit` for a body and died where it stood, and the error
   named the use site, which is not the mistake. *)

let runs label src expected =
  match Runner.run_string src with
  | Ok v -> Alcotest.(check string) label expected v
  | Error m -> Alcotest.failf "%s: %s" label m

let test_a_binding_in_a_block () =
  runs "one binding" "(let x = 1; x + 2)" "3";
  runs "two, in one block" "(let x = 1; let y = 2; x + y)" "3";
  runs "each sees the one before" "(let x = 1; let y = x + 1; y * 3)" "6";
  runs "statements after it"
    {|uses {IO}
import IO
(let x = 1; IO.println "a"; x + 1)|} "2";
  runs "a binding after a statement"
    {|uses {IO}
import IO
(IO.println "a"; let x = 1; x)|} "1";
  (* Every binding form reaches the same place in the parser. *)
  runs "annotated" "(let x : Int = 1; x + 1)" "2";
  runs "a function" "(let helper y = y + 1; helper 4)" "5";
  runs "an and group"
    "(let even n = if n == 0 then true else odd (n - 1) \
     and odd n = if n == 0 then false else even (n - 1); even 8)" "true"

(* The older spelling keeps its meaning: `in` scopes over one expression,
   and a `;` after it starts the next statement. *)
let test_the_in_form_is_unchanged () =
  runs "in scopes over its own expression" "(let x = 1 in x + 1; 9)" "9";
  (match Runner.run_string "(let x = 1 in x + 1; x + 2)" with
   | Ok v -> Alcotest.failf "expected x to be unbound, got %s" v
   | Error m ->
     if not (Lint.contains m "unbound variable 'x'") then
       Alcotest.failf "expected an unbound x, got: %s" m);
  runs "and it still works alone" "(let x = 1 in x + 1)" "2"

(* The one program whose meaning changes: a binding that bound nothing now
   binds. Pinned so the change is recorded rather than discovered. *)
let test_a_dead_binding_becomes_live () =
  runs "the inner binding wins" "let x = 0 in (let x = 1; x)" "1"

(* A block cannot end with a binding: nothing would read the name. It was
   silent before -- the binding took Unit for a body. *)
let test_a_block_cannot_end_with_a_binding () =
  refuses "on its own" "(let x = 1)" "this binding has no body";
  refuses "after a statement" {|(IO.println "a"; let x = 1)|} "this binding has no body";
  refuses "with a trailing semicolon" "(let x = 1;)" "this binding has no body"

(* ── A type on a pattern ─────────────────────────────────────────────────── *)

(* `(p: Pod)` gives a parameter a type, which is what lets a function read a
   field off one. The slot was refused before, with a message for the cons
   mistake -- and cons in a pattern is `[h :: t]`, in brackets, so the
   parenthesised form was never a pattern at all. One token tells them
   apart: a type starts with `Upper`, `'a` or `(`.

   Every parameter position funnels through the same two functions, so all
   of them gain it together. *)

(* `Ast.show_pat` prints the pattern under an annotation and not the
   annotation itself, so these compare a rendering that shows it. *)
let rec type_text (te : Ast.type_expr) =
  match te with
  | Ast.TEName n      -> n
  | Ast.TEQual (m, n) -> m ^ "." ^ n
  | Ast.TEVar v       -> "'" ^ v
  | Ast.TEApp (f, a)  -> type_text f ^ " " ^ type_text a
  | Ast.TETuple ts    -> "(" ^ String.concat ", " (List.map type_text ts) ^ ")"
  | Ast.TEFun (a, b, _) -> type_text a ^ " -> " ^ type_text b

let rec pat_text (p : Ast.pat) =
  match p with
  | Ast.PAnnot (inner, te) -> "(" ^ pat_text inner ^ ": " ^ type_text te ^ ")"
  | other -> Ast.show_pat other

let params_text src =
  let prog = parse_program src in
  match prog.items with
  | Ast.TLLet (_, params, _) :: _ ->
    String.concat " " (List.map pat_text params)
  | _ -> Alcotest.failf "expected a let with parameters from: %s" src

let expr_pats src =
  match parse src with
  | Fn (ps, _) -> String.concat " " (List.map pat_text ps)
  | Let (_, Fn (ps, _), _, _) -> String.concat " " (List.map pat_text ps)
  | Match (_, (p, _, _) :: _) -> pat_text p
  | With (_, p, _) -> pat_text p
  | e -> Alcotest.failf "no pattern in: %s" (Ast.show e)

let test_pattern_annotation () =
  let check = Alcotest.(check string) in
  check "a top-level let"   "(p: Pod)"           (params_text "let describe (p: Pod) = p.name");
  check "two of them"       "(a: Pod) (b: Pod)"  (params_text "let f (a: Pod) (b: Pod) = a");
  check "a local let"       "(p: Pod)"
    (expr_pats "let inner (p: Pod) = p.name in inner");
  check "a lambda"          "(p: Pod)"           (expr_pats "fn (p: Pod) -> p");
  check "an arm of a match" "(p: Pod)"           (expr_pats "match x with | (p: Pod) -> p");
  check "a resource bracket" "(d: Path)"         (expr_pats "with r as (d: Path) -> d");
  (* A type of any shape, not only a name. *)
  check "an applied type"   "(xs: List Pod)"     (expr_pats "fn (xs: List Pod) -> xs");
  check "a tuple type"      "((a, b): (Pod, Pod))"
    (expr_pats "fn ((a, b): (Pod, Pod)) -> a");
  check "an arrow type"     "(f: Pod -> String)"
    (expr_pats "fn (f: Pod -> String) -> f");
  (* The spacing is the author's; the parser reads both. *)
  check "a space before the colon" "(p: Pod)"    (expr_pats "fn (p : Pod) -> p")

(* The message this slot used to hold still meets the mistake it was written
   for. This is the regression that matters: the change edits the code path
   that produces it. *)
let test_the_cons_mistake_still_reports () =
  refuses "in a match arm" "match xs with | (x : xs) -> x"
    "a cons pattern is written in square brackets";
  refuses "in a parameter" "let f (x : xs) = x"
    "a cons pattern is written in square brackets";
  (* And the real cons pattern is untouched. *)
  Alcotest.(check string) "cons in brackets" "[h :: t]"
    (expr_pats "match xs with | [h :: t] -> h")

(* ── Brace maps ──────────────────────────────────────────────────────────── *)

let test_brace_map_literal () =
  e "brace map" "{x = 1, y = 2}" (MapLit [("x", Int 1); ("y", Int 2)]);
  e "empty map" "{}" (MapLit []);
  e "quoted key" {|{"two words" = 1}|} (MapLit [("two words", Int 1)]);
  e "nested in interpolation" {|"%{f {x = 1}}"|}
    (Interp ([("", App (Var "f", MapLit [("x", Int 1)]))], ""))

let test_brace_map_pattern () =
  e "rename" "match m with | {x = a} -> a"
    (Match (Var "m", [(PMap [("x", PVar "a")], None, Var "a")]));
  e "pun" "match m with | {x, y} -> x"
    (Match (Var "m", [(PMap [("x", PVar "x"); ("y", PVar "y")], None, Var "x")]));
  e "pun and rename mixed" "match m with | {x, y = b} -> b"
    (Match (Var "m", [(PMap [("x", PVar "x"); ("y", PVar "b")], None, Var "b")]));
  e "empty map pattern" "match m with | {} -> 0"
    (Match (Var "m", [(PMap [], None, Int 0)]));
  (match (try Ok (parse {|match m with | {"two words"} -> 0|})
          with Parser.ParseError _ as e -> Error e) with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "a quoted key must not pun")

let test_brace_import_destructure () =
  let prog = parse_program "let {test} = import Test\n1" in
  match prog.items with
  | [TLLetPat (PMap [("test", PVar "test")], _); TLExpr _] -> ()
  | _ -> Alcotest.fail "expected a TLLetPat with a punned PMap"

(* ── Literals ────────────────────────────────────────────────────────────── *)

let test_lits () =
  e "int"    "42"         (Int 42);
  e "float"  "3.14"       (Float 3.14);
  e "string" {|"hello"|}  (String "hello");
  e "true"   "true"       (Bool true);
  e "false"  "false"      (Bool false);
  e "unit"   "()"         Unit

let test_domain_lits () =
  e "path"     "/etc/foo"             (Path "/etc/foo");
  e "date"     "2024-01-15"           (DateTime "2024-01-15");
  e "duration" "5min"                 (Duration "5min");
  e "url"      "https://example.com"  (URL "https://example.com");
  e "ipv4"     "192.168.1.1"          (IPv4 "192.168.1.1");
  e "size"     "10MB"                 (Size "10MB")

(* ── Variables & constructors ────────────────────────────────────────────── *)

let test_vars () =
  e "ident"  "foo"   (Var "foo");
  e "upper"  "Some"  (Constr "Some");
  e "hole"   "?"     Hole

(* ── Unary operators ─────────────────────────────────────────────────────── *)

let test_unary () =
  e "neg"  "-42"    (UnOp ("-", Int 42));
  e "not"  "!true"  (UnOp ("!", Bool true))

(* ── Binary operators & precedence ──────────────────────────────────────── *)

let test_binop () =
  e "add"  "1 + 2"  (BinOp ("+", Int 1, Int 2));
  e "sub"  "1 - 2"  (BinOp ("-", Int 1, Int 2));
  e "mul"  "2 * 3"  (BinOp ("*", Int 2, Int 3));
  e "div"  "6 / 2"  (BinOp ("/", Int 6, Int 2))

let test_precedence () =
  e "mul before add"
    "1 + 2 * 3"
    (BinOp ("+", Int 1, BinOp ("*", Int 2, Int 3)));
  e "left assoc"
    "1 * 2 + 3"
    (BinOp ("+", BinOp ("*", Int 1, Int 2), Int 3));
  e "cmp lower than arith"
    "x + 1 == y"
    (BinOp ("==", BinOp ("+", Var "x", Int 1), Var "y"))

let test_pipeline () =
  e "pipeline"
    "xs |> map f"
    (BinOp ("|>", Var "xs", App (Var "map", Var "f")))

let test_logical () =
  e "and"  "a && b"  (BinOp ("&&", Var "a", Var "b"));
  e "or"   "a || b"  (BinOp ("||", Var "a", Var "b"))

(* ── Parentheses ─────────────────────────────────────────────────────────── *)

let test_parens () =
  e "override prec"
    "(1 + 2) * 3"
    (BinOp ("*", BinOp ("+", Int 1, Int 2), Int 3))

(* ── Function application ────────────────────────────────────────────────── *)

let test_app () =
  e "one arg"   "f x"    (App (Var "f", Var "x"));
  e "two args"  "f x y"  (App (App (Var "f", Var "x"), Var "y"));
  e "unit arg"  "f ()"   (App (Var "f", Unit));
  e "app then op"
    "f x + 1"
    (BinOp ("+", App (Var "f", Var "x"), Int 1));
  (* A newline inside an open paren doesn't end the argument list -- it's
     still one call, not a parse error and not two unrelated expressions. *)
  e "multi-line args inside parens"
    "f (1, 2,\n   3, 4)"
    (App (Var "f", Tuple [Int 1; Int 2; Int 3; Int 4]));
  e "newline before an argument's own open paren"
    "f (g x,\n   (h y))"
    (App (Var "f", Tuple [App (Var "g", Var "x"); App (Var "h", Var "y")]))

(* A newline inside an open paren must never cause a multi-line call to be
   silently read as two separate top-level statements (the original bug: a
   truncated application not nested in any pending close-bracket consumer
   just let a fresh top-level expression start on the next line, with no
   error at all). *)
let test_program_newlines () =
  let prog = parse_program "f (1, 2,\n   3, 4)" in
  Alcotest.(check int) "single top-level item" 1 (List.length prog.items);
  (match prog.items with
   | [TLExpr e] ->
     Alcotest.(check expr) "single App top-level item"
       (App (Var "f", Tuple [Int 1; Int 2; Int 3; Int 4])) e
   | _ -> Alcotest.fail "expected a single TLExpr top-level item")

(* The other half of the same rule: a newline ends a statement only at the
   top level, so anything that raises the bracket depth and does not put it
   back stops every later line from ending. `type X (T, U)` tries the named
   field list first and rewinds when there is no `:`, and the rewind used to
   leave the `(` counted -- after which `let n = 5` swallowed the definition
   below it, and `wand f` wrote the joined reading back to the file. *)
let test_rewind_keeps_bracket_depth () =
  let prog = parse_program "type Span (Int, Int)\nlet n = 5\nf n\n" in
  Alcotest.(check int) "three top-level items" 3 (List.length prog.items);
  match prog.items with
  | [_; TLLet (_, [], body); TLExpr _] ->
    Alcotest.(check expr) "the binding stops at its own line" (Int 5)
      (Ast.strip_located body)
  | _ -> Alcotest.fail "expected a type, a binding and an expression"

(* And the same rule for the payload a constructor takes in brackets. The
   uppercase payload already stopped at a line back at the declaration's own
   column; the bracketed one did not, so `type Colour = Red` followed by a
   line opening with `(` read that line as Red's field list. `wand f` writes
   a leading unary minus bracketed, which turned two items into source the
   parser then refused. Found by test/fuzz. *)
let test_a_bracketed_payload_stops_at_the_line_end () =
  let prog = parse_program "type Colour = Red\n(1, 2)\n" in
  Alcotest.(check int) "two top-level items" 2 (List.length prog.items);
  (match prog.items with
   | [_; TLExpr e] ->
     Alcotest.(check expr) "the bracket starts its own item"
       (Tuple [Int 1; Int 2]) (Ast.strip_located e)
   | _ -> Alcotest.fail "expected a type and an expression");
  (* Indented past the `type`, it is still the payload it looks like. *)
  let payload = parse_program "type Shape = Circle\n  (Int)\nlet f x = x\n" in
  Alcotest.(check int) "an indented bracket stays the payload" 2
    (List.length payload.items);
  (* The single-constructor shorthand reads the same way, so a field list
     back at column one is not one -- and says so where it is written. *)
  refuses "the shorthand's field list" "type Span\n(Int, Int)\n" "expected =";
  let shorthand = parse_program "type Span\n  (Int, Int)\nlet n = 5\n" in
  Alcotest.(check int) "an indented field list is still one" 2
    (List.length shorthand.items)

(* The bracket a constructor takes as its payload has to be one the statement
   is still open for. `peek` steps over a newline without asking, so a
   constructor alone on its line absorbed a bracket that opened the next item
   -- `H` and `("s" H)` were two items, and reading the formatter's own output
   back made them one, so `wand f` never settled. Found by test/fuzz. *)
let test_a_constructor_payload_stops_at_the_line_end () =
  let prog = parse_program "H\n(\"s\" H)\n" in
  Alcotest.(check int) "two top-level items" 2 (List.length prog.items);
  (* Indented past the item, it is the payload it looks like. *)
  let payload = parse_program "let a = S\n  (1)\nlet b = 2\n" in
  Alcotest.(check int) "an indented bracket stays the payload" 2
    (List.length payload.items);
  (* And a bracket the statement itself opened suspends the rule, so a
     newline inside one means nothing -- which is the general rule, not an
     exception made here. *)
  Alcotest.(check expr) "inside a bracket it is still the payload"
    (parse "(S (1))") (parse "(S\n(1))");
  (* On one line, nothing changes. *)
  Alcotest.(check expr) "on one line" (parse "S(1)") (parse "S (1)")

(* ── Tuples ──────────────────────────────────────────────────────────────── *)

let test_tuple () =
  e "pair"    "(1, 2)"     (Tuple [Int 1; Int 2]);
  e "triple"  "(1, 2, 3)"  (Tuple [Int 1; Int 2; Int 3])

(* ── Lists ───────────────────────────────────────────────────────────────── *)

let test_list () =
  e "empty"    "[]"           (List []);
  e "one"      "[1]"          (List [Int 1]);
  e "several"  "[1, 2, 3]"   (List [Int 1; Int 2; Int 3]);
  e "strings"  {|["a", "b"]|} (List [String "a"; String "b"])

(* ── Constructor application (named) ─────────────────────────────────────── *)

let test_constr_app () =
  e "named construction"
    {|Point (x = 1, y = 2)|}
    (ConstrApp ("Point", [Some "x", Int 1; Some "y", Int 2]));
  e "single named field"
    "Circle (radius = 5)"
    (ConstrApp ("Circle", [Some "radius", Int 5]))


(* ── Constructor application (positional) ────────────────────────────────── *)

(* Parentheses group a tuple; several arguments are juxtaposed. This used to
   depend on the constructor's declared arity, which the parser only knew for
   types declared in the file being parsed -- so `Some (1, 2)` parsed one way
   inside Option and another way everywhere else. These assert the parse
   itself, not merely that a program using it typechecks. *)

let test_constr_positional () =
  e "parenthesised arguments are one tuple"
    "Some (1, 2)"
    (App (Constr "Some", Tuple [Int 1; Int 2]));
  e "regardless of the constructor"
    "Whatever (1, 2)"
    (App (Constr "Whatever", Tuple [Int 1; Int 2]));
  e "several arguments are juxtaposed"
    "R 3 4"
    (App (App (Constr "R", Int 3), Int 4));
  e "a single parenthesised argument is just that argument"
    "Some (1)"
    (App (Constr "Some", Int 1));
  (* Empty parentheses are undecided like a list of bare names: a
     construction naming no fields where the constructor has them, and the
     constructor applied to unit where it does not. *)
  e "no arguments"
    "Some ()"
    (ConstrBare ("Some", []));
  (* As in a pattern, bare names are left for the declaration to read. *)
  e "bare identifiers stay undecided"
    "Point(x, y)"
    (ConstrBare ("Point", ["x"; "y"]));
  e "a pun after a named field"
    "Point(x = 1, y)"
    (ConstrApp ("Point", [(Some "x", Int 1); (Some "y", Var "y")]));
  (* `T(r, b = 3)` was the update long before puns, and stays it. *)
  e "a name before a named field is the base of an update"
    "Point(x, y = 1)"
    (ConstrUpdate ("Point", Var "x", [("y", Int 1)]))


(* Only a `,` makes a constructor's bracket a field list -- a construction
   names its fields one per comma, so a `;` in there can only be the
   ordinary block. It used to be a parse error, which `wand f` reached by
   writing an application head without its brackets: `(Some)(a; b)` parsed,
   and came back as `Some (a; b)`, which did not. Found by test/fuzz. *)

let test_constr_bracket_holds_a_block () =
  e "a block is the payload"
    "Some (1; 2)"
    (App (Constr "Some", Seq (Int 1, Int 2)));
  e "and reads the same as the head written out"
    "(Some)(1; 2)"
    (parse "Some (1; 2)");
  e "a trailing `;` is allowed, as in any block"
    "Some (1;)"
    (App (Constr "Some", Int 1));
  e "a binding opens one"
    "Some (let x = 1; x)"
    (parse "(Some)(let x = 1; x)");
  runs "and it evaluates" "match Some (1; 2) with | Some n -> n | None -> 0" "2";
  runs "a binding in it evaluates"
    "match Some (let x = 1; x + 1) with | Some n -> n | None -> 0" "2"

let test_constr_positional_patterns () =
  (* Bare names are the one list the parser leaves undecided, so the tuple
     under a constructor is written with something that is not one. *)
  e "a tuple pattern under a constructor"
    "match v with\n| Some (a, [b]) -> a"
    (Match (Var "v", [
      (PConstr ("Some", [PTuple [PVar "a"; PList [PVar "b"]]]), None, Var "a");
    ]));
  e "juxtaposed sub-patterns"
    "match v with\n| R a b -> a"
    (Match (Var "v", [
      (PConstr ("R", [PVar "a"; PVar "b"]), None, Var "a");
    ]))

(* ── Handler cases ────────────────────────────────────────────────────────── *)

(* An operation is the call it stands for with a `!` where its dot goes. The
   lexer hands back `FS!` as one Upper token and `read_file` as an
   identifier, so the case parser has to join them. *)

let test_handler_arm_operations () =
  e "a family-qualified operation"
    "handle body with\n| FS!read_file p k -> p"
    (Handle (Var "body", [
      Ast.EffectCase ("FS!read_file", PVar "p", "k", Var "p");
    ]));
  e "several cases, including a return"
    "handle body with\n| Shell!run c k -> c\n| return r -> r"
    (Handle (Var "body", [
      Ast.EffectCase ("Shell!run", PVar "c", "k", Var "c");
      Ast.ReturnCase (PVar "r", Var "r");
    ]))


(* ── Field access ────────────────────────────────────────────────────────── *)

let test_field () =
  e "field"  "r.name"  (Field (Var "r", "name"));
  e "chain"  "r.a.b"   (Field (Field (Var "r", "a"), "b"));
  (* `.field` binds to the immediately preceding atom, not the whole
     application chain: `f x.y` is `f (x.y)`, not `(f x).y`. *)
  e "field on argument"
    "f x.y"
    (App (Var "f", Field (Var "x", "y")));
  e "chained field on argument"
    "f x.a.b"
    (App (Var "f", Field (Field (Var "x", "a"), "b")))

(* ── Let ─────────────────────────────────────────────────────────────────── *)

let test_let () =
  e "simple"
    "let x = 1 in x"
    (Let (PVar "x", Int 1, Var "x", LetIn));
  e "wildcard"
    "let _ = f () in 0"
    (Let (Wild, App (Var "f", Unit), Int 0, LetIn));
  e "tuple pattern"
    "let (a, b) = p in a"
    (Let (PTuple [PVar "a"; PVar "b"], Var "p", Var "a", LetIn))

(* Local multi-equation continuation clauses accept either a bare repeated
   name or a repeated `let` (matching the top-level `let f 0 = .. / let
   f n = ..` syntax) -- both must parse to the identical merged AST. *)
let test_local_multi_equation () =
  let bare = parse "let f 0 = 1\nf n = n * f (n - 1)\nin f 5" in
  let with_let = parse "let f 0 = 1\nlet f n = n * f (n - 1)\nin f 5" in
  Alcotest.(check expr) "let-prefixed matches bare form" bare with_let;
  (match bare with
   | Let (PVar "f", Fn ([PVar "_p0"], Match (Var "_p0", [(Int 0, None, _); (PVar "n", None, _)])), _, _) -> ()
   | _ -> Alcotest.fail "expected a merged multi-equation Fn/Match")

(* `T(r, b = 3)` is `r` with `b` replaced. `T(a, b)` is still `T` applied to
   a pair: the `ident =` after the comma is what separates them, and the
   parser asks only once the first item is read. *)
let test_record_update () =
  e "one field"
    "T(r, b = 3)"
    (ConstrUpdate ("T", Var "r", [("b", Int 3)]));
  e "several fields"
    "T(r, a = 1, b = 2)"
    (ConstrUpdate ("T", Var "r", [("a", Int 1); ("b", Int 2)]));
  e "the base is any expression"
    "T(f x, b = 3)"
    (ConstrUpdate ("T", App (Var "f", Var "x"), [("b", Int 3)]));
  (* Bare names are the one list the parser leaves undecided, so the pair
     payload is written with something that is not one. *)
  e "a pair payload is untouched"
    "T(a, [b])"
    (App (Constr "T", Tuple [Var "a"; List [Var "b"]]))

(* A pattern carries a type wherever a pattern is written, including inside
   a constructor's payload -- which is where a decoder's result lands. *)
let test_annotated_payload_pattern () =
  let pat_of src =
    match parse src with
    | Match (_, (p, _, _) :: _) -> p
    | e -> Alcotest.failf "no match pattern in: %s" (Ast.show e)
  in
  (* `show_pat` prints through an annotation, so these read the node. *)
  (match pat_of "match r with | Ok (v: T) -> 1" with
   | PConstr ("Ok", [PAnnot (PVar "v", _)]) -> ()
   | p -> Alcotest.failf "one payload: got %s" (Ast.show_pat p));
  (match pat_of "match r with | Ok (v: T, n) -> 1" with
   | PConstr ("Ok", [PTuple [PAnnot (PVar "v", _); PVar "n"]]) -> ()
   | p -> Alcotest.failf "inside a tuple payload: got %s" (Ast.show_pat p))

(* ── If / then / else ────────────────────────────────────────────────────── *)

let test_if () =
  e "basic"
    "if x then 1 else 0"
    (If (Var "x", Int 1, Int 0));
  e "nested"
    "if a then if b then 1 else 2 else 3"
    (If (Var "a", If (Var "b", Int 1, Int 2), Int 3));
  (* A missing `else` is `else ()`, so there is one conditional rather than
     two, and the branch is checked against Unit like any other. *)
  e "one-armed"
    "if x then f y"
    (If (Var "x", App (Var "f", Var "y"), Unit));
  e "one-armed does not reach across a line for its branch"
    "if x then f ()\ng ()"
    (If (Var "x", App (Var "f", Unit), Unit))

(* ── Match ───────────────────────────────────────────────────────────────── *)

let test_match () =
  e "two cases"
    "match n with\n| 0 -> false\n| _ -> true"
    (Match (Var "n", [
      (Int 0, None, Bool false);
      (Wild,  None, Bool true);
    ]));
  e "guard"
    "match x with\n| n when n > 0 -> true\n| _ -> false"
    (Match (Var "x", [
      (PVar "n", Some (BinOp (">", Var "n", Int 0)), Bool true);
      (Wild,     None,                               Bool false);
    ]))

let test_constr_pats () =
  e "nullary"
    "match opt with\n| None -> 0\n| Some x -> x"
    (Match (Var "opt", [
      (PConstr ("None", []),          None, Int 0);
      (PConstr ("Some", [PVar "x"]), None, Var "x");
    ]));
  e "result"
    "match r with\n| Ok x -> x\n| Err e -> 0"
    (Match (Var "r", [
      (PConstr ("Ok",  [PVar "x"]), None, Var "x");
      (PConstr ("Err", [PVar "e"]), None, Int 0);
    ]))

(* ── Named constructor patterns ──────────────────────────────────────────── *)

let test_constr_named_pats () =
  e "named pattern"
    "match p with\n| Point (x = a, y = b) -> a"
    (Match (Var "p", [
      (PConstrNamed ("Point", [("x", PVar "a"); ("y", PVar "b")]), None, Var "a")
    ]));
  e "single named field pattern"
    "match c with\n| Circle (radius = r) -> r"
    (Match (Var "c", [
      (PConstrNamed ("Circle", [("radius", PVar "r")]), None, Var "r")
    ]));
  (* Bare identifiers are kept as written: which reading they carry is the
     declaration's to decide, and the declaration may be in another file. *)
  e "bare identifiers stay undecided"
    "match p with\n| Point(x, y) -> x"
    (Match (Var "p", [
      (PConstrBare ("Point", ["x"; "y"]), None, Var "x")
    ]));
  e "a space does not decide it"
    "match p with\n| Point (x, y) -> x"
    (Match (Var "p", [
      (PConstrBare ("Point", ["x"; "y"]), None, Var "x")
    ]));
  e "one identifier binds the payload either way"
    "match c with\n| Circle (r) -> r"
    (Match (Var "c", [
      (PConstr ("Circle", [PVar "r"]), None, Var "r")
    ]));
  e "a pun beside a named field"
    "match p with\n| Point(x, y = b) -> x"
    (Match (Var "p", [
      (PConstrNamed ("Point", [("x", PVar "x"); ("y", PVar "b")]), None, Var "x")
    ]));
  e "a pun after a named field"
    "match p with\n| Point(x = a, y) -> a"
    (Match (Var "p", [
      (PConstrNamed ("Point", [("x", PVar "a"); ("y", PVar "y")]), None, Var "a")
    ]));
  (* Anything that is not a bare name is a payload, and stays one. *)
  e "a wildcard is not a field name"
    "match p with\n| Point(_, y) -> y"
    (Match (Var "p", [
      (PConstr ("Point", [PTuple [Wild; PVar "y"]]), None, Var "y")
    ]))

(* A type or a constructor reached through the module that declares it. The
   module's name is uppercase for a standard library module and lowercase for
   a file, so both spellings have to parse. *)

let test_qualified_names () =
  e "a qualified constructor"
    "Test.Pass"
    (Qualified ("Test", Constr "Pass"));
  e "through a lowercase module name"
    "one.Live"
    (Qualified ("one", Constr "Live"));
  e "a qualified construction"
    "Foo.Conf(port = 1)"
    (Qualified ("Foo", ConstrApp ("Conf", [(Some "port", Int 1)])));
  e "a qualified constructor applied"
    "Foo.Wrap 3"
    (App (Qualified ("Foo", Constr "Wrap"), Int 3));
  (* A lowercase member is a value, and stays field access. *)
  e "a value is not a constructor"
    "one.thing"
    (Field (Var "one", "thing"));
  e "a qualified pattern"
    "match o with\n| Test.Pass s -> s"
    (Match (Var "o", [
      (PQualified ("Test", PConstr ("Pass", [PVar "s"])), None, Var "s")
    ]));
  e "a qualified pattern through a lowercase module"
    "match o with\n| one.Live -> 1"
    (Match (Var "o", [
      (PQualified ("one", PConstr ("Live", [])), None, Int 1)
    ]))

(* ── Fn (lambda) ─────────────────────────────────────────────────────────── *)

let test_fn () =
  e "one arg"
    "fn x -> x + 1"
    (Fn ([PVar "x"], BinOp ("+", Var "x", Int 1)));
  e "two args"
    "fn x y -> x + y"
    (Fn ([PVar "x"; PVar "y"], BinOp ("+", Var "x", Var "y")));
  e "wildcard arg"
    "fn _ -> 0"
    (Fn ([Wild], Int 0))

(* ── Sequencing in parentheses ──────────────────────────────────────────── *)

let test_paren_seq () =
  e "two statements"
    "(1; 2)"
    (Seq (Int 1, Int 2));
  (* Nested to the right, so every discarded statement is a Seq's own first
     child -- where the typechecker records its type for V-DROP1. *)
  e "three nest right"
    "(1; 2; 3)"
    (Seq (Int 1, Seq (Int 2, Int 3)));
  e "trailing semicolon"
    "(1; 2;)"
    (Seq (Int 1, Int 2));
  e "grouping parens unchanged"
    "(1)"
    (Int 1);
  e "in a function body"
    "fn x -> (x + 1; x * 2)"
    (Fn ([PVar "x"], Seq (BinOp ("+", Var "x", Int 1), BinOp ("*", Var "x", Int 2))))

(* ── `try` and the `with` below it ───────────────────────────────────────── *)

(* The hint for `try e with cases` is for someone writing OCaml, where that
   is one statement. It was owed on any following `with`, which made a
   top-level `with ... as ... ->` under a `try` unparseable -- a construct
   the reference gives four examples of. The layout rule decides now: a
   `with` still inside the statement gets the hint, one that opens a
   statement of its own is a resource bracket. *)

let parses label src =
  match (try Ok (parse_program src) with Parser.ParseError (_, m) -> Error m) with
  | Ok _ -> ()
  | Error m -> Alcotest.failf "%s: %s" label m

let test_try_then_with () =
  (* Still one statement, so the hint is still owed. *)
  refuses "same line" "let r = try f () with | Error e -> 1"
    "try takes no cases";
  refuses "indented past the try" "let h = 1\ntry h\n  with r as d -> h"
    "try takes no cases";
  (* Back at the `try`'s column, so it opens a statement of its own. *)
  parses "a resource bracket below" "let h = 1\ntry h\nwith h as d -> d";
  parses "a resource bracket alone" "with h as d -> d"

(* ── Suite ───────────────────────────────────────────────────────────────── *)

(* Equations for one function are a single definition, so they must be
   written together and agree on arity. Both used to be accepted silently:
   a later `let f` after a gap shadowed or merged depending on arity, and a
   differing arity started a fresh binding that shadowed the first. *)

let parse_error label src needle =
  match (try Ok (parse_program src) with
         | Parser.ParseError (_, m) -> Error m
         | Failure m -> Error m) with
  | Ok _ -> Alcotest.failf "%s: expected a parse error" label
  | Error m ->
    let contains hay nee =
      let hn = String.length hay and nn = String.length nee in
      let found = ref false in
      for i = 0 to hn - nn do
        if nn <= hn && String.sub hay i nn = nee then found := true
      done; !found
    in
    if not (contains m needle) then
      Alcotest.failf "%s: expected %S in error, got: %s" label needle m

(* ── Manifests ───────────────────────────────────────────────────────────── *)

(* Position is part of the grammar: a manifest a reader has to search for is
   worth no more than none, so it is the first item rather than an item that
   happens to come first by convention. *)

let test_manifest_parses () =
  let prog = parse_program "uses {Shell, FS.Write}\nlet x = 1\nx" in
  (match prog.Ast.manifest with
   | Some (labels, _) ->
     Alcotest.(check (list string)) "the declared effects"
       ["Shell"; "FS.Write"] (List.map fst labels);
     Alcotest.(check bool) "bare Shell has no allowlist" true
       (List.for_all (fun (_, allow) -> allow = None) labels)
   | None -> Alcotest.fail "expected a manifest");
  (* An empty one is a claim in its own right: this file touches nothing. *)
  (match (parse_program "uses {}\nlet x = 1\nx").Ast.manifest with
   | Some ([], _) -> ()
   | _ -> Alcotest.fail "expected an empty manifest")

let test_manifest_shell_allowlist () =
  let prog =
    parse_program
      "uses {Shell(git, docker-compose, node.js, g++, \"7zip\", /opt/bin/deploy), FS.Write}\nlet x = 1\nx"
  in
  (match prog.Ast.manifest with
   | Some ([("Shell", Some allow); ("FS.Write", None)], _) ->
     Alcotest.(check (list string)) "the binaries"
       ["git"; "docker-compose"; "node.js"; "g++"; "7zip"; "/opt/bin/deploy"]
       allow
   | _ -> Alcotest.fail "expected Shell(...) then FS.Write");
  parse_error "empty Shell()"
    "uses {Shell()}\nlet x = 1\nx"
    "Shell() admits nothing";
  parse_error "duplicate binary"
    "uses {Shell(git, git)}\nlet x = 1\nx"
    "already in this Shell(...) list";
  parse_error "args on another label"
    "uses {FS.Write(git)}\nlet x = 1\nx"
    "only Shell takes a list of binaries"

let test_manifest_is_optional () =
  match (parse_program "let x = 1\nx").Ast.manifest with
  | None -> ()
  | Some _ -> Alcotest.fail "a file without one should have none"

let test_manifest_must_come_first () =
  parse_error "after another item"
    "let x = 1\nuses {Shell}\nx"
    "must be the first thing in the file";
  parse_error "a second manifest"
    "uses {Shell}\nlet x = 1\nuses {FS.Read}\nx"
    "already has one"

(* Comments and a shebang may precede it -- a note explaining why a script
   needs an effect belongs directly above the line granting it. *)
let test_manifest_may_follow_comments () =
  let prog = parse_program "-- deploys to prod\nuses {Shell}\nlet x = 1\nx" in
  match prog.Ast.manifest with
  | Some ([("Shell", None)], _) -> ()
  | _ -> Alcotest.fail "a comment above the manifest should be allowed"

let test_equation_contiguity () =
  parse_error "later equation after an intervening binding"
    "let f 0 = 0\nlet x = 1\nlet f 1 = 1\nf 0"
    "already defined above";
  parse_error "redefinition with a different arity"
    "let f 0 = 0\nlet x = 1\nlet f 1 2 = 3\nf 0"
    "already defined above";
  (* Consecutive equations remain one definition. *)
  ignore (parse_program "let fib 0 = 0\nlet fib 1 = 1\nlet fib n = n\nfib 3");
  (* Value bindings may still be rebound. *)
  ignore (parse_program "let x = 1\nlet x = 2\nx")

let test_equation_arity () =
  parse_error "arity differs inside a contiguous group"
    "let f 0 = 0\nlet f 1 2 = 3\nf 0"
    "every equation of a function must take the same number";
  parse_error "zero-parameter clause after a function clause"
    "let f 0 = 0\nlet f = 3\nf 0"
    "every equation of a function must take the same number"

(* A handler case that does not resume still had to name a continuation it
   would never use, which reads as an oversight rather than a decision. *)
let test_handler_continuation_binder () =
  let case src = Lexer.tokenize src |> Parser.parse_program in
  let ok label src =
    match case src with
    | _ -> ()
    | exception Parser.ParseError (_, m) -> Alcotest.failf "%s: %s" label m
  in
  ok "a named continuation" {|handle 1 with
| Shell!run c k -> k "x"|};
  ok "_ where the case does not resume" {|handle 1 with
| Shell!run c _ -> "x"|};
  ok "_ for both the argument and the continuation" {|handle 1 with
| Shell!run _ _ -> "x"|};
  (* Anything else still has to be one or the other. *)
  match case {|handle 1 with
| Shell!run _ 3 -> "x"|} with
  | _ -> Alcotest.fail "expected a parse error for a literal continuation"
  | exception Parser.ParseError (_, m) ->
    Alcotest.(check bool) "the message says what is allowed" true
      (let sub = "or _ if it is not resumed" in
       let n = String.length sub and t = String.length m in
       let rec at i = i + n <= t && (String.sub m i n = sub || at (i + 1)) in
       at 0)

(* An application crosses a line where the line below is indented past the
   definition it continues. wand does have a layout rule now, and this is
   it: indentation is what tells a continuation from a new definition.

   This used to be refused, with an error telling the reader to bracket it.
   The refusal was the honest thing to do while there was no rule -- an
   identifier starts a definition as readily as it continues one -- but it
   also meant a newline ended a statement at the top level and meant nothing
   inside brackets, which is two rules for one piece of punctuation and the
   reason a binding inside a block needed a `;` or an `in` that the same
   binding at the top level did not. *)
let test_indented_continuation () =
  let parse src = Lexer.tokenize src |> Parser.parse_program in
  let ok label src =
    match parse src with
    | _ -> ()
    | exception Parser.ParseError (_, m) -> Alcotest.failf "%s: %s" label m
  in
  ok "an indented application continues"
    "let add a b = a + b\nlet f x =\n  add\n    x\n    1\n";
  (* Back at the definition's own column it is a new definition, not a
     continuation -- which is the half of the rule that has to hold for a
     file of definitions to read as one. *)
  ok "a line at the same column starts a definition"
    "let a = 1\nlet b = 2\nb\n";
  (* And a whole file indented consistently is a layout choice, not one
     enormous application. *)
  ok "consistently indented items stay separate"
    "type C = R | G\n     let f c = match c with | R -> 1 | G -> 2\n     f R\n";
  (* Everything that legitimately spans lines must still parse. *)
  ok "a pipeline continuation" "let n = xs\n  |> f\n";
  ok "if/else across lines" "let f x = if x then\n  1\n  else 2\n";
  ok "a list across lines" "let xs = [\n  1,\n  2\n]\n";
  ok "a let..in body" "let f x =\n  let y = 1 in\n  y\n";
  ok "multi-equation clauses" "let g 0 = 1\nlet g n = 2\n";
  (* A whole file indented is a layout choice, not a mistake. Only a bare
     expression is the shape a stray argument takes, so only that is
     rejected -- a rule that fired on correct code would teach a reader to
     stop reading errors. *)
  ok "an indented definition" "let a = 1\n     let b = 2\n     b\n";
  ok "definitions separated by ;" "let f b = match b with | true -> 1 | false -> 0; f true"


(* ── Effects in a written type ───────────────────────────────────────────── *)

(* The printer emits four shapes; the grammar has to read all four back, or a
   signature `wand t` reports is not one you can paste into an annotation. *)

let te_of src =
  match parse_program src with
  | { items = [TLLet (_, _, Ast.Annot (te, _))]; _ } -> te
  | _ -> Alcotest.failf "expected one annotated let, from: %s" src

let ann ty = Printf.sprintf "let f : %s = g" ty

let test_written_effects_shapes () =
  Alcotest.(check bool) "a labelled set" true
    (te_of (ann "Unit -> String ! {Shell}")
     = TEFun (TEName "Unit", TEName "String",
              Some { te_labels = ["Shell"]; te_var = None }));
  Alcotest.(check bool) "several labels, dotted" true
    (te_of (ann "Unit -> String ! {FS.Read, Shell}")
     = TEFun (TEName "Unit", TEName "String",
              Some { te_labels = ["FS.Read"; "Shell"]; te_var = None }));
  Alcotest.(check bool) "a variable alone" true
    (te_of (ann "'a -> 'a ! 'e")
     = TEFun (TEVar "a", TEVar "a",
              Some { te_labels = []; te_var = Some "e" }));
  Alcotest.(check bool) "labels and a tail" true
    (te_of (ann "Unit -> Unit ! {Shell | 'e}")
     = TEFun (TEName "Unit", TEName "Unit",
              Some { te_labels = ["Shell"]; te_var = Some "e" }));
  Alcotest.(check bool) "nothing written stays inferred" true
    (te_of (ann "Int -> Int")
     = TEFun (TEName "Int", TEName "Int", None))

(* Only the innermost arrow carries them, as in an inferred type: supplying
   one argument of several does nothing until the last arrives. *)
let test_written_effects_land_on_the_inner_arrow () =
  Alcotest.(check bool) "a curried type" true
    (te_of (ann "Int -> Int -> Int ! {IO}")
     = TEFun (TEName "Int",
              TEFun (TEName "Int", TEName "Int",
                     Some { te_labels = ["IO"]; te_var = None }),
              None));
  (* Parenthesised, the effects belong to the argument's own arrow. *)
  Alcotest.(check bool) "an effectful argument" true
    (te_of (ann "(Unit -> Int ! 'e) -> Int ! 'e")
     = TEFun (TEFun (TEName "Unit", TEName "Int",
                     Some { te_labels = []; te_var = Some "e" }),
              TEName "Int",
              Some { te_labels = []; te_var = Some "e" }))

let () =
  Alcotest.run "Parser" [
    "written effects", [
      Alcotest.test_case "the four shapes"     `Quick test_written_effects_shapes;
      Alcotest.test_case "innermost arrow"     `Quick test_written_effects_land_on_the_inner_arrow;
    ];
    "a binding in a block", [
      Alcotest.test_case "binds for the rest"   `Quick test_a_binding_in_a_block;
      Alcotest.test_case "in is unchanged"      `Quick test_the_in_form_is_unchanged;
      Alcotest.test_case "a dead binding lives" `Quick test_a_dead_binding_becomes_live;
      Alcotest.test_case "cannot end a block"   `Quick test_a_block_cannot_end_with_a_binding;
    ];
    "a type on a pattern", [
      Alcotest.test_case "every position"   `Quick test_pattern_annotation;
      Alcotest.test_case "cons still fails" `Quick test_the_cons_mistake_still_reports;
    ];
    "layout", [
      Alcotest.test_case "indented continuation" `Quick test_indented_continuation;
    ];
    "handler cases", [
      Alcotest.test_case "continuation binder" `Quick test_handler_continuation_binder;
    ];
    "literals", [
      Alcotest.test_case "literals"        `Quick test_lits;
      Alcotest.test_case "domain literals" `Quick test_domain_lits;
    ];
    "expressions", [
      Alcotest.test_case "variables"    `Quick test_vars;
      Alcotest.test_case "unary"        `Quick test_unary;
      Alcotest.test_case "binop"        `Quick test_binop;
      Alcotest.test_case "precedence"   `Quick test_precedence;
      Alcotest.test_case "pipeline"     `Quick test_pipeline;
      Alcotest.test_case "logical"      `Quick test_logical;
      Alcotest.test_case "parens"       `Quick test_parens;
      Alcotest.test_case "application"  `Quick test_app;
      Alcotest.test_case "program newlines" `Quick test_program_newlines;
      Alcotest.test_case "rewind keeps bracket depth" `Quick
        test_rewind_keeps_bracket_depth;
      Alcotest.test_case "bracketed payload stops at the line end" `Quick
        test_a_bracketed_payload_stops_at_the_line_end;
      Alcotest.test_case "constructor payload stops at the line end" `Quick
        test_a_constructor_payload_stops_at_the_line_end;
      Alcotest.test_case "tuple"        `Quick test_tuple;
      Alcotest.test_case "list"         `Quick test_list;
      Alcotest.test_case "brace map literal" `Quick test_brace_map_literal;
      Alcotest.test_case "brace map pattern" `Quick test_brace_map_pattern;
      Alcotest.test_case "brace import destructure" `Quick test_brace_import_destructure;
      Alcotest.test_case "constr app"    `Quick test_constr_app;
      Alcotest.test_case "constr positional" `Quick test_constr_positional;
      Alcotest.test_case "constr bracket holds a block" `Quick
        test_constr_bracket_holds_a_block;
      Alcotest.test_case "constr positional patterns" `Quick test_constr_positional_patterns;
      Alcotest.test_case "handler cases"  `Quick test_handler_arm_operations;
      Alcotest.test_case "field"        `Quick test_field;
    ];
    "manifests", [
      Alcotest.test_case "parses"          `Quick test_manifest_parses;
      Alcotest.test_case "shell allowlist" `Quick test_manifest_shell_allowlist;
      Alcotest.test_case "optional"        `Quick test_manifest_is_optional;
      Alcotest.test_case "must come first" `Quick test_manifest_must_come_first;
      Alcotest.test_case "after comments"  `Quick test_manifest_may_follow_comments;
    ];
    "multi-equation", [
      Alcotest.test_case "contiguity"   `Quick test_equation_contiguity;
      Alcotest.test_case "arity"        `Quick test_equation_arity;
    ];
    "constructs", [
      Alcotest.test_case "let"          `Quick test_let;
      Alcotest.test_case "try then with" `Quick test_try_then_with;
      Alcotest.test_case "record update" `Quick test_record_update;
      Alcotest.test_case "annotated payload" `Quick test_annotated_payload_pattern;
      Alcotest.test_case "local multi-equation" `Quick test_local_multi_equation;
      Alcotest.test_case "if"           `Quick test_if;
      Alcotest.test_case "match"        `Quick test_match;
      Alcotest.test_case "constr pats"       `Quick test_constr_pats;
      Alcotest.test_case "constr named pats" `Quick test_constr_named_pats;
      Alcotest.test_case "qualified names"  `Quick test_qualified_names;
      Alcotest.test_case "fn"           `Quick test_fn;
      Alcotest.test_case "paren seq"    `Quick test_paren_seq;
    ];
  ]
