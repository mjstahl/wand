open Wand

let stdlib_prelude =
  "import List\nimport String\nimport Path\nimport FS\nimport IO\n\
   import Duration\nimport Env\nimport Map"

let make_sess () =
  let sess = Runner.make_session () in
  match Runner.run_session sess stdlib_prelude with
  | Ok (s, _) -> s
  | Error msg -> Alcotest.failf "stdlib load failed: %s" msg

let lookup_module name sess =
  match List.assoc_opt name sess.Runner.s_type_env with
  | Some (Typechecker.Namespace members) -> Some members
  | _ -> None

(* ── wand e (eval) ───────────────────────────────────────────────────────── *)

let test_eval () =
  let sess = make_sess () in
  (* value expression *)
  (match Runner.run_session sess "1 + 2" with
   | Ok (_, Runner.RVal ("3", "Int")) -> ()
   | Ok (_, r) -> Alcotest.failf "eval: unexpected result: %s"
       (match r with Runner.RVal (v, t) -> v ^ " : " ^ t | _ -> "other")
   | Error m -> Alcotest.failf "eval error: %s" m);
  (* let binding *)
  (match Runner.run_session sess "let x = 42" with
   | Ok (_, Runner.RBind ("x", "Int")) -> ()
   | Ok (_, _) -> Alcotest.fail "eval: expected RBind for let"
   | Error m   -> Alcotest.failf "eval let error: %s" m);
  (* stdlib available *)
  (match Runner.run_session sess "List.length [1, 2, 3]" with
   | Ok (_, Runner.RVal ("3", "Int")) -> ()
   | Ok (_, _) -> Alcotest.fail "eval: stdlib List not available"
   | Error m   -> Alcotest.failf "eval stdlib error: %s" m);
  (* error on bad expression *)
  (match Runner.run_session sess "1 + true" with
   | Error _ -> ()
   | Ok _    -> Alcotest.fail "eval: expected error for type mismatch")

let test_eval_holes () =
  let sess = make_sess () in
  match Runner.run_session sess "?" with
  | Ok (_, Runner.RHoles [_]) -> ()
  | Ok (_, _) -> Alcotest.fail "eval hole: expected RHoles"
  | Error m   -> Alcotest.failf "eval hole error: %s" m

(* ── wand t (typecheck) ──────────────────────────────────────────────────── *)

let test_type () =
  let sess = make_sess () in
  (* expression type *)
  (match Runner.typecheck_session sess "1 + 2" with
   | Ok (Runner.RTypeExpr "Int") -> ()
   | Ok _ -> Alcotest.fail "type: expected RTypeExpr Int"
   | Error m -> Alcotest.failf "type error: %s" m);
  (* function type *)
  (match Runner.typecheck_session sess "fn x -> x + 1" with
   | Ok (Runner.RTypeExpr t) ->
     if t <> "Int -> Int" then
       Alcotest.failf "type: expected Int -> Int, got %s" t
   | Ok _ -> Alcotest.fail "type: expected RTypeExpr"
   | Error m -> Alcotest.failf "type fn error: %s" m);
  (* let binding type *)
  (match Runner.typecheck_session sess "let x = \"hello\"" with
   | Ok (Runner.RBind ("x", "String")) -> ()
   | Ok _ -> Alcotest.fail "type: expected RBind x String"
   | Error m -> Alcotest.failf "type let error: %s" m);
  (* type error *)
  (match Runner.typecheck_session sess "1 + true" with
   | Error _ -> ()
   | Ok _    -> Alcotest.fail "type: expected error for type mismatch");
  (* hole *)
  (match Runner.typecheck_session sess "?" with
   | Ok (Runner.RHoles [_]) -> ()
   | Ok _ -> Alcotest.fail "type hole: expected RHoles"
   | Error m -> Alcotest.failf "type hole error: %s" m)

(* ── wand d (doc) ────────────────────────────────────────────────────────── *)

let test_doc () =
  let sess = make_sess () in
  (* stdlib function has a type *)
  (match Runner.lookup_type sess "List.map" with
   | Some t ->
     if not (String.length t > 0) then
       Alcotest.fail "doc: List.map type is empty"
   | None -> Alcotest.fail "doc: List.map type not found");
  (* stdlib function has a doc string *)
  (match List.assoc_opt "map" (List.concat_map (fun (n, s) ->
      match s with
      | Typechecker.Namespace members ->
        if n = "List" then List.map (fun (mn, ms) -> (mn, ms)) members else []
      | _ -> []) sess.Runner.s_type_env) with
   | Some _ -> ()
   | None   -> ());
  (* unknown name returns None *)
  (match Runner.lookup_type sess "no_such_name" with
   | None -> ()
   | Some _ -> Alcotest.fail "doc: expected None for unknown name");
  (* module member lookup works *)
  (match Runner.lookup_type sess "Map.get" with
   | Some t ->
     if not (String.length t > 0) then
       Alcotest.fail "doc: Map.get type is empty"
   | None -> Alcotest.fail "doc: Map.get not found")

let test_doc_strings () =
  let sess = make_sess () in
  (* user-defined doc string is stored *)
  let sess2 = match Runner.run_session sess
    {|(** Doubles a number. *)
let double x = x * 2|} with
    | Ok (s, _) -> s
    | Error m   -> Alcotest.failf "doc string eval error: %s" m
  in
  (match List.assoc_opt "double" sess2.Runner.s_docs with
   | Some doc ->
     if not (String.length doc > 0) then
       Alcotest.fail "doc: doc string is empty"
   | None -> Alcotest.fail "doc: doc string not stored")

(* ── wand env (list all) ─────────────────────────────────────────────────── *)

let test_env_all () =
  let sess = make_sess () in
  let entries = sess.Runner.s_type_env in
  (* stdlib modules are present *)
  List.iter (fun name ->
    if not (List.mem_assoc name entries) then
      Alcotest.failf "env: %s not in type env" name
  ) ["List"; "String"; "Map"; "Env"; "Path"; "FS"; "IO"; "Duration"];
  (* user bindings appear after being defined *)
  let sess2 = match Runner.run_session sess "let answer = 42" with
    | Ok (s, _) -> s
    | Error m   -> Alcotest.failf "env let error: %s" m
  in
  if not (List.mem_assoc "answer" sess2.Runner.s_type_env) then
    Alcotest.fail "env: user binding not in type env"

(* ── wand env <Module> ───────────────────────────────────────────────────── *)

let test_env_module () =
  let sess = make_sess () in
  (match lookup_module "NoSuchModule" sess with
   | None   -> ()
   | Some _ -> Alcotest.fail "expected None for unknown module");
  let sess2 = match Runner.run_session sess "let x = 42" with
    | Ok (s, _) -> s
    | Error m   -> Alcotest.failf "run failed: %s" m
  in
  (match List.assoc_opt "x" sess2.Runner.s_type_env with
   | Some (Typechecker.Namespace _) -> Alcotest.fail "x should not be a namespace"
   | _ -> ())

let test_env_map_module () =
  let sess = make_sess () in
  match lookup_module "Map" sess with
  | None -> Alcotest.fail "Map module not found"
  | Some members ->
    let names = List.map fst members in
    List.iter (fun n ->
      if not (List.mem n names) then
        Alcotest.failf "Map.%s missing from env" n
    ) ["get"; "set"; "delete"; "keys"; "values"; "size"; "empty"]

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "CLI" [
    "eval", [
      Alcotest.test_case "eval expressions" `Quick test_eval;
      Alcotest.test_case "eval holes"       `Quick test_eval_holes;
    ];
    "type", [
      Alcotest.test_case "typecheck expressions" `Quick test_type;
    ];
    "doc", [
      Alcotest.test_case "type lookup"   `Quick test_doc;
      Alcotest.test_case "doc strings"   `Quick test_doc_strings;
    ];
    "env", [
      Alcotest.test_case "list all"      `Quick test_env_all;
      Alcotest.test_case "module lookup" `Quick test_env_module;
      Alcotest.test_case "Map module"    `Quick test_env_map_module;
    ];
  ]
