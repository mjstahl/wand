open Wand

let stdlib_prelude =
  "import List\nimport String\nimport Path\nimport FS\nimport IO\n\
   import Duration\nimport Process\nimport Env\nimport Map"

let make_sess () =
  let sess = Runner.make_session () in
  match Runner.run_session sess stdlib_prelude with
  | Ok (s, _) -> s
  | Error msg -> Alcotest.failf "stdlib load failed: %s" msg

let lookup_module name sess =
  match List.assoc_opt name sess.Runner.s_type_env with
  | Some (Typechecker.Namespace members) -> Some members
  | _ -> None

(* ── wand env <Module> ───────────────────────────────────────────────────── *)

let test_env_module () =
  let sess = make_sess () in
  (* known module returns its members *)
  (match lookup_module "Process" sess with
   | None -> Alcotest.fail "Process module not found"
   | Some members ->
     let names = List.map fst members in
     List.iter (fun n ->
       if not (List.mem n names) then
         Alcotest.failf "Process.%s missing from env" n
     ) ["run"; "run_quiet"; "exit_code"; "pid"]);
  (* unknown name returns None *)
  (match lookup_module "NoSuchModule" sess with
   | None -> ()
   | Some _ -> Alcotest.fail "expected None for unknown module");
  (* binding (non-namespace) returns None *)
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
    "env module", [
      Alcotest.test_case "module lookup"     `Quick test_env_module;
      Alcotest.test_case "Map module lookup" `Quick test_env_map_module;
    ];
  ]
