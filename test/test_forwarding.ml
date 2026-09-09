open Wand
open Wand.Ast

(* `Evaluator.forwarding_builtin` decides whether a definition is nothing but
   a hand-off to a builtin, and so may be replaced by that builtin. Getting
   the guard wrong binds a name to the wrong function and says nothing, so
   every shape that must be refused is pinned here rather than left to the
   fact that no standard library definition currently has it. *)

let env : Evaluator.env =
  [ ("a_builtin", Evaluator.VBuiltin (fun v -> v));
    ("not_a_builtin", Evaluator.VInt 1) ]

let p n = PVar n
let v n = Var n
let app f x = App (f, x)

let qualifies label params body =
  match Evaluator.forwarding_builtin env params body with
  | Some _ -> ()
  | None   -> Alcotest.failf "%s: expected this to forward, and it did not" label

let refused label params body =
  match Evaluator.forwarding_builtin env params body with
  | None   -> ()
  | Some _ -> Alcotest.failf "%s: expected this to be refused, and it was not" label

let test_forwards () =
  qualifies "one argument, passed straight through"
    [p "s"] (app (v "a_builtin") (v "s"));
  qualifies "two arguments, in order"
    [p "a"; p "b"] (app (app (v "a_builtin") (v "a")) (v "b"));
  qualifies "three arguments, in order"
    [p "a"; p "b"; p "c"]
    (app (app (app (v "a_builtin") (v "a")) (v "b")) (v "c"));
  (* The parser wraps bodies in `Located`, so the real shape must pass. *)
  qualifies "wrapped in Located"
    [p "s"] (Located (Token.point 1 1 0, app (v "a_builtin") (v "s")))

let test_refused () =
  refused "reordered arguments"
    [p "a"; p "b"] (app (app (v "a_builtin") (v "b")) (v "a"));
  refused "an argument used twice"
    [p "a"] (app (app (v "a_builtin") (v "a")) (v "a"));
  refused "fewer arguments than parameters"
    [p "a"; p "b"] (app (v "a_builtin") (v "a"));
  refused "an argument that is not a parameter"
    [p "a"] (app (app (v "a_builtin") (v "a")) (v "b"));
  refused "an argument of its own, as String.lines has"
    [p "s"] (app (app (v "a_builtin") (String "\n")) (v "s"));
  refused "work done on the answer, as String.empty? has"
    [p "s"] (BinOp ("==", app (v "a_builtin") (v "s"), Int 0));
  refused "a head that is not a builtin"
    [p "s"] (app (v "not_a_builtin") (v "s"));
  refused "a head that is not bound at all"
    [p "s"] (app (v "nowhere") (v "s"));
  refused "no parameters"
    [] (v "a_builtin");
  refused "a parameter that is not a plain name"
    [PList []] (app (v "a_builtin") (v "s"));
  (* `let f x = f x` must not find itself: at the point its own definition is
     read, `f` is not bound to a builtin. *)
  refused "a definition that names itself"
    [p "x"] (app (v "f") (v "x"))

let () =
  Alcotest.run "Forwarding definitions" [
    "forwards", [ Alcotest.test_case "shapes that qualify" `Quick test_forwards ];
    "refused",  [ Alcotest.test_case "shapes that must not" `Quick test_refused ];
  ]
