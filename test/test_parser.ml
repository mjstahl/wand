open Wand
open Ast

let parse s =
  Lexer.tokenize s |> Parser.parse_expr

let expr = Alcotest.(testable Ast.pp Ast.equal)

let e label input expected =
  Alcotest.(check expr) label expected (parse input)

let parse_program s =
  Lexer.tokenize s |> Parser.parse_program

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
  e "date"     "2024-01-15"           (Date "2024-01-15");
  e "duration" "5min"                 (Duration "5min");
  e "url"      "https://example.com"  (Url "https://example.com");
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
  e "no arguments"
    "Some ()"
    (App (Constr "Some", Unit))

let test_constr_positional_patterns () =
  e "a tuple pattern under a constructor"
    "match v with\n| Some (a, b) -> a"
    (Match (Var "v", [
      (PConstr ("Some", [PTuple [PVar "a"; PVar "b"]]), None, Var "a");
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
    (Let (PVar "x", Int 1, Var "x"));
  e "wildcard"
    "let _ = f () in 0"
    (Let (Wild, App (Var "f", Unit), Int 0));
  e "tuple pattern"
    "let (a, b) = p in a"
    (Let (PTuple [PVar "a"; PVar "b"], Var "p", Var "a"))

(* Local multi-equation continuation clauses accept either a bare repeated
   name or a repeated `let` (matching the top-level `let f 0 = .. / let
   f n = ..` syntax) -- both must parse to the identical merged AST. *)
let test_local_multi_equation () =
  let bare = parse "let f 0 = 1\nf n = n * f (n - 1)\nin f 5" in
  let with_let = parse "let f 0 = 1\nlet f n = n * f (n - 1)\nin f 5" in
  Alcotest.(check expr) "let-prefixed matches bare form" bare with_let;
  (match bare with
   | Let (PVar "f", Fn ([PVar "_p0"], Match (Var "_p0", [(Int 0, None, _); (PVar "n", None, _)])), _) -> ()
   | _ -> Alcotest.fail "expected a merged multi-equation Fn/Match")

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

(* An application cannot cross a line: an identifier starts a new definition
   just as well as it continues one, and wand has no layout rule to tell
   them apart. Left alone that parses as separate definitions and fails much
   later as an unbound name that is plainly in scope, which is a bad way to
   learn a layout rule. *)
let test_indented_continuation () =
  let parse src = Lexer.tokenize src |> Parser.parse_program in
  (match parse "let add a b = a + b\nlet f x =\n  add\n    x\n    1\n" with
   | _ -> Alcotest.fail "expected the indented continuation to be rejected"
   | exception Parser.ParseError (_, m) ->
     let says sub =
       let n = String.length sub and t = String.length m in
       let rec at i = i + n <= t && (String.sub m i n = sub || at (i + 1)) in
       at 0
     in
     Alcotest.(check bool) "names the real problem" true
       (says "indented as though it continued the definition above");
     Alcotest.(check bool) "and says what to do" true (says "one line"));
  (* Everything that legitimately spans lines must still parse. *)
  let ok label src =
    match parse src with
    | _ -> ()
    | exception Parser.ParseError (_, m) -> Alcotest.failf "%s: %s" label m
  in
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

let () =
  Alcotest.run "Parser" [
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
      Alcotest.test_case "tuple"        `Quick test_tuple;
      Alcotest.test_case "list"         `Quick test_list;
      Alcotest.test_case "brace map literal" `Quick test_brace_map_literal;
      Alcotest.test_case "brace map pattern" `Quick test_brace_map_pattern;
      Alcotest.test_case "brace import destructure" `Quick test_brace_import_destructure;
      Alcotest.test_case "constr app"    `Quick test_constr_app;
      Alcotest.test_case "constr positional" `Quick test_constr_positional;
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
      Alcotest.test_case "local multi-equation" `Quick test_local_multi_equation;
      Alcotest.test_case "if"           `Quick test_if;
      Alcotest.test_case "match"        `Quick test_match;
      Alcotest.test_case "constr pats"       `Quick test_constr_pats;
      Alcotest.test_case "constr named pats" `Quick test_constr_named_pats;
      Alcotest.test_case "fn"           `Quick test_fn;
      Alcotest.test_case "paren seq"    `Quick test_paren_seq;
    ];
  ]
