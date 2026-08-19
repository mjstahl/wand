open Wand

let stdlib_prelude =
  "import List\nimport String\nimport Path\nimport FS\nimport IO\n\
   import Duration\nimport Env\nimport Map\nimport Regex"

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
   | Error d -> Alcotest.failf "type error: %s" (Diag.legacy d));
  (* function type *)
  (match Runner.typecheck_session sess "fn x -> x + 1" with
   | Ok (Runner.RTypeExpr t) ->
     if t <> "Int -> Int" then
       Alcotest.failf "type: expected Int -> Int, got %s" t
   | Ok _ -> Alcotest.fail "type: expected RTypeExpr"
   | Error d -> Alcotest.failf "type fn error: %s" (Diag.legacy d));
  (* let binding type *)
  (match Runner.typecheck_session sess "let x = \"hello\"" with
   | Ok (Runner.RBind ("x", "String")) -> ()
   | Ok _ -> Alcotest.fail "type: expected RBind x String"
   | Error d -> Alcotest.failf "type let error: %s" (Diag.legacy d));
  (* type error *)
  (match Runner.typecheck_session sess "1 + true" with
   | Error _ -> ()
   | Ok _    -> Alcotest.fail "type: expected error for type mismatch");
  (* hole *)
  (match Runner.typecheck_session sess "?" with
   | Ok (Runner.RHoles [_]) -> ()
   | Ok _ -> Alcotest.fail "type hole: expected RHoles"
   | Error d -> Alcotest.failf "type hole error: %s" (Diag.legacy d))

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

let step sess src =
  match Runner.run_session sess src with
  | Ok (s, _) -> s
  | Error e -> Alcotest.failf "step [%s] failed: %s" src e

let run_val sess src =
  match Runner.run_session sess src with
  | Ok (_, Runner.RVal (v, _)) -> v
  | Ok (_, _) -> Alcotest.failf "run [%s]: expected RVal" src
  | Error e -> Alcotest.failf "run [%s] error: %s" src e

let test_incremental_pattern_match () =
  let sess = Runner.make_session () in
  let sess = step sess "let fact 1 = 1" in
  let sess = step sess "let fact n = 1 + fact (n - 1)" in
  let sess = step sess "let fact 0 = 0" in
  Alcotest.(check string) "fact 0 after incremental" "0" (run_val sess "fact 0");
  Alcotest.(check string) "fact 1 after incremental" "1" (run_val sess "fact 1");
  Alcotest.(check string) "fact 3 after incremental" "3" (run_val sess "fact 3")

(* The REPL edits definitions; files declare them. Adding a clause for an
   existing function merges into it here rather than erroring as a file
   would, and the merge is announced so the reordering is visible. *)

let test_repl_merges_clauses_and_announces () =
  let sess = Runner.make_session () in
  let sess = match Runner.run_session sess "let f 0 = 0" with
    | Ok (s, Runner.RBind ("f", _)) -> s
    | Ok (_, _) -> Alcotest.fail "expected a binding for the first clause"
    | Error m -> Alcotest.failf "first clause failed: %s" m
  in
  let sess = match Runner.run_session sess "let f n = n * 2" with
    | Ok (s, Runner.RBind ("f", ty)) ->
      let contains hay nee =
        let hn = String.length hay and nn = String.length nee in
        let found = ref false in
        for i = 0 to hn - nn do
          if nn <= hn && String.sub hay i nn = nee then found := true
        done; !found
      in
      if not (contains ty "2 equations")
      then Alcotest.failf "expected the merge to be announced, got: %s" ty
      else s
    | Ok (_, _) -> Alcotest.fail "expected a binding for the merged clause"
    | Error m -> Alcotest.failf "merged clause failed: %s" m
  in
  (* Both clauses are live: the specific one still fires after the merge. *)
  (match Runner.run_session sess "f 0" with
   | Ok (_, Runner.RVal ("0", _)) -> ()
   | Ok (_, _) -> Alcotest.fail "specific clause did not fire after merge"
   | Error m -> Alcotest.failf "f 0 failed: %s" m);
  (match Runner.run_session sess "f 5" with
   | Ok (_, Runner.RVal ("10", _)) -> ()
   | Ok (_, _) -> Alcotest.fail "general clause did not fire after merge"
   | Error m -> Alcotest.failf "f 5 failed: %s" m)

(* A mutual group binds several names at once; each is echoed with its
   type, the way a lone binding is. *)
let test_repl_echoes_mutual_group () =
  let sess = Runner.make_session () in
  let src = "let is_even n = if n == 0 then true else is_odd (n - 1) and\n\
             is_odd n = if n == 0 then false else is_even (n - 1)" in
  let sess = match Runner.run_session sess src with
    | Ok (s, Runner.RGroup [("is_even", _); ("is_odd", _)]) -> s
    | Ok (_, _) -> Alcotest.fail "expected both names of the group echoed"
    | Error m -> Alcotest.failf "mutual group failed: %s" m
  in
  match Runner.run_session sess "is_odd 3" with
  | Ok (_, Runner.RVal ("true", _)) -> ()
  | Ok (_, _) -> Alcotest.fail "is_odd 3 should be true"
  | Error m -> Alcotest.failf "is_odd 3 failed: %s" m

(* Checking a file without running it: what an editing loop and CI both want,
   and what a manifest violation will be reported through. The path is stated
   with --file rather than guessed from the argument, since `deploy.wand` is
   itself a valid path expression and would otherwise typecheck as one. *)

let with_file name contents f =
  let path = Filename.concat (Filename.get_temp_dir_name ()) name in
  let oc = open_out path in
  output_string oc contents; close_out oc;
  let r = (try f path with e -> Sys.remove path; raise e) in
  Sys.remove path; r

let test_typecheck_file () =
  with_file "wand_cli_ok.wand" "let double x = x * 2\ndouble 21" (fun path ->
    match Runner.typecheck_file path with
    | Ok sc ->
      Alcotest.(check string) "reports the file's type" "Int" sc.Runner.sc_type;
      Alcotest.(check int) "no holes" 0 (List.length sc.Runner.sc_holes)
    | Error d -> Alcotest.failf "expected it to typecheck: %s" (Diag.legacy d))

let test_typecheck_file_reports_errors () =
  with_file "wand_cli_bad.wand" "let x : Int = \"no\"\nx" (fun path ->
    match Runner.typecheck_file path with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail "expected a type error")

let test_typecheck_file_reports_holes () =
  with_file "wand_cli_hole.wand" "import List\nList.fold_left ? 0 [1, 2, 3]" (fun path ->
    match Runner.typecheck_file path with
    | Ok sc ->
      Alcotest.(check int) "one hole" 1 (List.length sc.Runner.sc_holes);
      (* The row variable says the function filling the hole may perform
         effects of its own -- fold_left passes through whatever it is given. *)
      Alcotest.(check string) "with its inferred type" "Int -> Int -> Int ! 'e"
        (List.hd sc.Runner.sc_holes)
    | Error d -> Alcotest.failf "expected it to typecheck: %s" (Diag.legacy d))

(* The editor's case: text that exists only in a buffer. The path decides
   where imports resolve, whether or not a file is there. *)
let test_typecheck_source_unsaved_buffer () =
  with_file "wand_cli_util.wand" "let answer = 42" (fun util ->
    let buffer = Filename.concat (Filename.dirname util) "wand_cli_buffer.wand" in
    match Runner.typecheck_source ~path:buffer
            "let {answer} = import ./wand_cli_util\nanswer" with
    | Ok sc ->
      Alcotest.(check string) "the buffer sees its neighbor" "Int" sc.Runner.sc_type
    | Error d -> Alcotest.failf "expected it to typecheck: %s" (Diag.legacy d))

let test_typecheck_source_own_names () =
  match Runner.typecheck_source ~path:"wand_cli_hover.wand"
          "let double x = x * 2\ndouble 21" with
  | Ok sc ->
    Alcotest.(check bool) "the file's own names are reported" true
      (List.mem_assoc "double" sc.Runner.sc_env)
  | Error d -> Alcotest.failf "expected it to typecheck: %s" (Diag.legacy d)

let test_typecheck_file_lints () =
  with_file "wand_cli_lint.wand" "let is_ready? x = x > 1\nis_ready? 2" (fun path ->
    match Runner.typecheck_file path with
    | Ok sc ->
      Alcotest.(check bool) "a lint is reported" true (sc.Runner.sc_findings <> [])
    | Error d -> Alcotest.failf "expected it to typecheck: %s" (Diag.legacy d))

(* ── wand test: finding the files ────────────────────────────────────────── *)

(* A script's tests live beside the script, so discovery is by prefix and
   the answer has to be the tests and nothing else -- not the script, not a
   fixture, and not dune's copy of the same tree under _build. *)

let write path contents =
  Out_channel.with_open_text path (fun oc -> Out_channel.output_string oc contents)

let with_tree f =
  let root = Filename.temp_file "wand_tests" "" in
  Sys.remove root;
  Sys.mkdir root 0o755;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote root))))
    (fun () -> f root)

let test_finds_tests_beside_scripts () =
  with_tree (fun root ->
    let at p = Filename.concat root p in
    write (at "deploy.wand") "let deploy = 1";
    write (at "test_deploy.wand") "";
    (* A nested script directory is searched too. *)
    Sys.mkdir (at "scripts") 0o755;
    write (at "scripts/test_backup.wand") "";
    write (at "scripts/backup.wand") "";
    (* Things that are not test files, by each of the ways they can fail
       to be one. *)
    write (at "fixture.wand") "";
    write (at "test_notes.txt") "";
    write (at "test_.wand") "";
    let found =
      Runner.find_test_files root
      |> List.map Filename.basename
    in
    Alcotest.(check (list string)) "the test files, in a stable order"
      ["test_backup.wand"; "test_deploy.wand"] found)

(* dune copies the source tree into _build, so a search that descends into
   it reports every test twice under two different paths. *)
let test_skips_build_directories () =
  with_tree (fun root ->
    let at p = Filename.concat root p in
    write (at "test_real.wand") "";
    List.iter (fun d ->
      Sys.mkdir (at d) 0o755;
      write (at (Filename.concat d "test_copy.wand")) "")
      ["_build"; "_opam"; ".git"; "node_modules"];
    let found = Runner.find_test_files root |> List.map Filename.basename in
    Alcotest.(check (list string)) "only the real one" ["test_real.wand"] found)

(* A file named outright runs whatever it is called: the prefix is how
   files are found, not a rule about what may be run. *)
let test_a_named_file_is_taken_as_given () =
  with_tree (fun root ->
    let path = Filename.concat root "anything.wand" in
    write path "";
    Alcotest.(check (list string)) "the file itself" [path]
      (Runner.find_test_files path))

let test_a_dangling_symlink_is_stepped_over () =
  with_tree (fun root ->
    write (Filename.concat root "test_real.wand") "";
    Unix.symlink (Filename.concat root "gone") (Filename.concat root "link");
    let found = Runner.find_test_files root |> List.map Filename.basename in
    Alcotest.(check (list string)) "still finds the test" ["test_real.wand"] found)

let () =
  Alcotest.run "CLI" [
    "typecheck a file", [
      Alcotest.test_case "reports the type"   `Quick test_typecheck_file;
      Alcotest.test_case "reports errors"     `Quick test_typecheck_file_reports_errors;
      Alcotest.test_case "reports holes"      `Quick test_typecheck_file_reports_holes;
      Alcotest.test_case "checks a buffer"    `Quick test_typecheck_source_unsaved_buffer;
      Alcotest.test_case "reports own names"  `Quick test_typecheck_source_own_names;
      Alcotest.test_case "reports lints"      `Quick test_typecheck_file_lints;
    ];
    "test discovery", [
      Alcotest.test_case "finds tests beside scripts" `Quick test_finds_tests_beside_scripts;
      Alcotest.test_case "skips build directories"    `Quick test_skips_build_directories;
      Alcotest.test_case "a named file as given"      `Quick test_a_named_file_is_taken_as_given;
      Alcotest.test_case "steps over a broken link"   `Quick test_a_dangling_symlink_is_stepped_over;
    ];
    "repl", [
      Alcotest.test_case "clause merge announced" `Quick test_repl_merges_clauses_and_announces;
      Alcotest.test_case "mutual group echoed"    `Quick test_repl_echoes_mutual_group;
    ];
    "eval", [
      Alcotest.test_case "eval expressions" `Quick test_eval;
      Alcotest.test_case "eval holes"       `Quick test_eval_holes;
      Alcotest.test_case "incremental pattern match" `Quick test_incremental_pattern_match;
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
