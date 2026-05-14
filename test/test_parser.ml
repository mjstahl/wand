open Wand
open Ast

let parse s =
  Lexer.tokenize s |> Parser.parse_expr

let expr = Alcotest.(testable Ast.pp Ast.equal)

let e label input expected =
  Alcotest.(check expr) label expected (parse input)

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
    (BinOp ("+", App (Var "f", Var "x"), Int 1))

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

(* ── Field access ────────────────────────────────────────────────────────── *)

let test_field () =
  e "field"  "r.name"  (Field (Var "r", "name"));
  e "chain"  "r.a.b"   (Field (Field (Var "r", "a"), "b"))

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

(* ── If / then / else ────────────────────────────────────────────────────── *)

let test_if () =
  e "basic"
    "if x then 1 else 0"
    (If (Var "x", Int 1, Int 0));
  e "nested"
    "if a then if b then 1 else 2 else 3"
    (If (Var "a", If (Var "b", Int 1, Int 2), Int 3))

(* ── Match ───────────────────────────────────────────────────────────────── *)

let test_match () =
  e "two arms"
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

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Parser" [
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
      Alcotest.test_case "tuple"        `Quick test_tuple;
      Alcotest.test_case "list"         `Quick test_list;
      Alcotest.test_case "constr app"    `Quick test_constr_app;
      Alcotest.test_case "field"        `Quick test_field;
    ];
    "constructs", [
      Alcotest.test_case "let"          `Quick test_let;
      Alcotest.test_case "if"           `Quick test_if;
      Alcotest.test_case "match"        `Quick test_match;
      Alcotest.test_case "constr pats"       `Quick test_constr_pats;
      Alcotest.test_case "constr named pats" `Quick test_constr_named_pats;
      Alcotest.test_case "fn"           `Quick test_fn;
    ];
  ]
