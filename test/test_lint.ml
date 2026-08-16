open Wand

let sess () = Runner.make_session ()

let findings src =
  match Runner.lint_session (sess ()) src with
  | Ok fs -> fs
  | Error m -> Alcotest.failf "lint failed: %s\nsource:\n%s" m src

let codes src = List.map (fun (f : Lint.finding) -> Lint_rules.code f.Lint.rule) (findings src)

let fires label src code =
  let got = codes src in
  if not (List.mem code got) then
    Alcotest.failf "%s: expected %s, got [%s]" label code (String.concat "; " got)

let silent label src =
  match codes src with
  | [] -> ()
  | got -> Alcotest.failf "%s: expected no findings, got [%s]" label (String.concat "; " got)

(* ── Individual rules ────────────────────────────────────────────────────── *)

let test_pred1 () =
  fires "non-Bool predicate" "let big? n = n * 2\nbig? 3" "V-PRED1";
  silent "Bool predicate" "let big? n = n > 2\nbig? 3";
  (* The rule is one-directional: a Bool-returning function need not be `?`. *)
  silent "Bool without ?" "let positive n = n > 0\npositive 1"

let test_pred2 () =
  fires "is_ prefix on a ?-named function" "let is_ready? x = x > 1\nis_ready? 2"
    "V-PRED2";
  silent "the bare form" "let ready? x = x > 1\nready? 2";
  (* `is_` on a name without `?` is not this rule's business. *)
  silent "no ? suffix" "let is_ready x = x > 1\nis_ready 2"

let test_or1 () =
  fires "Result with a Unit error" "let f x : Result Unit Int = Ok x\nf 1" "V-OR1";
  silent "Result with a reason" "let f x : Result String Int = Ok x\nf 1"

let test_name1 () =
  fires "trailing-underscore parameter" "let rename old_ new_ = old_ ++ new_\nrename \"a\" \"b\""
    "V-NAME1";
  silent "ordinary parameters" "let rename src dst = src ++ dst\nrename \"a\" \"b\"";
  (* A bare `_` is a wildcard, not an escaped name. *)
  silent "wildcard parameter" "let f _ = 1\nf 2"

(* Permitting more than the file uses is the safe direction, so it is
   advisory: --strict must not fail a build over caution. *)
let test_uses1 () =
  fires "manifest permits an unused effect"
    "uses {Shell, FS.Write}\nlet x = 1\nx" "A-USES1";
  silent "manifest matching what the file does"
    "uses {Shell}\nlet publish! () = $(rsync -a . host:/srv)\npublish!";
  silent "no manifest at all" "let x = 1\nx";
  (* `uses {}` is not advice: a file that reaches outside itself for nothing
     has nothing to declare, so the line should go rather than shrink. *)
  (match findings "uses {Shell}\nlet x = 1\nx" with
   | [f] ->
     Alcotest.(check bool) "suggests removal, not an empty manifest" true
       (let t = f.Lint.text in
        (not (List.exists (fun sub ->
           let n = String.length sub and m = String.length t in
           let rec at i = i + n <= m && (String.sub t i n = sub || at (i + 1)) in
           at 0) ["uses {}"]))
        && (let sub = "removed" and m = String.length t in
            let n = String.length sub in
            let rec at i = i + n <= m && (String.sub t i n = sub || at (i + 1)) in
            at 0))
   | fs -> Alcotest.failf "expected one finding, got %d" (List.length fs));
  let over = findings "uses {Shell}\nlet x = 1\nx" in
  Alcotest.(check bool) "never fails --strict" false
    (List.exists Lint.fails_strict over)

(* A file that reaches outside itself and says nothing about it. Advisory,
   because a file without a manifest is legal -- but a manifest is only
   worth having if it makes code better, so this is where a file is told
   what better looks like. *)
(* A statement whose value is a Result loses the failure it carries. Nothing
   else reports it: the file typechecks, the script exits 0, and the write
   that did not happen is never mentioned. *)
let test_drop1 () =
  fires "a discarded Result"
    "uses {FS.Write, IO}\nimport FS\nimport IO\nFS.write_file /tmp/x.txt \"hi\"\nIO.println \"done\""
    "V-DROP1";
  (* Binding to `_` says the failure does not matter, which is an answer. *)
  silent "discarded on purpose"
    "uses {FS.Write, IO}\nimport FS\nimport IO\nlet _ = FS.write_file /tmp/x.txt \"hi\"\nIO.println \"done\"";
  (* The `!` sibling raises, so the failure is not lost. *)
  silent "the raising sibling"
    "uses {FS.Write, IO}\nimport FS\nimport IO\nFS.write_file! /tmp/x.txt \"hi\"\nIO.println \"done\"";
  (* Discarding a String is what running a command for its effect looks like,
     so only Results are worth a finding. *)
  silent "a discarded String"
    "uses {Shell, IO}\nimport IO\n$(echo hi)\nIO.println \"done\"";
  (* The last item is the file's value, not something thrown away. *)
  silent "a Result as the file's value"
    "uses {FS.Write}\nimport FS\nFS.write_file /tmp/x.txt \"hi\"";
  (* `(e1; e2)` discards e1 the same way a bare statement does, so the same
     rule watches it. *)
  fires "a Result discarded by `;`"
    "uses {FS.Write}\nimport FS\nlet go () = (FS.write_file /tmp/x.txt \"hi\"; ())\ngo ()"
    "V-DROP1";
  silent "a seq whose value is the Result"
    "uses {FS.Write}\nimport FS\nlet go () = ((); FS.write_file /tmp/x.txt \"hi\")\ngo ()"

let test_uses2 () =
  fires "effects and no manifest"
    "let publish! () = $(rsync -a . host:/srv)\npublish!" "A-USES2";
  (* Saying so is the whole point, so having said it ends the matter. *)
  silent "the same file, declared"
    "uses {Shell}\nlet publish! () = $(rsync -a . host:/srv)\npublish!";
  silent "a file that reaches outside nothing" "let x = 1\nx";
  (* Raise is not a capability and never appears in a manifest, so a file
     that only raises has nothing it could declare. *)
  silent "raising alone"
    "import List\nlet head! xs = List.get! 0 xs\nhead! [1]";
  let undeclared = findings "let publish! () = $(rsync -a . host:/srv)\npublish!" in
  Alcotest.(check bool) "never fails --strict" false
    (List.exists Lint.fails_strict undeclared)

let test_shell1 () =
  fires "multi-stage pipeline"
    "let c = $(git log --oneline | grep fix | wc -l | tr -d \" \")\nc" "A-SHELL1";
  silent "single command" "uses {Shell}\nlet c = $(git status)\nc";
  silent "one pipe" "uses {Shell}\nlet c = $(ls | wc -l)\nc"

(* ── Classification ──────────────────────────────────────────────────────── *)

(* Only must-fix rules may fail a build. An advisory one that could fail it
   would teach its audience to ignore every rule beside it. *)
let test_kinds () =
  Alcotest.(check bool) "V-PRED1 must be fixed" true
    (Lint_rules.kind Lint_rules.V_PRED1 = Lint_rules.Violation);
  Alcotest.(check bool) "A-SHELL1 is advisory" true
    (Lint_rules.kind Lint_rules.A_SHELL1 = Lint_rules.Advisory);
  let shell = findings "let c = $(a | b | c | d)\nc" in
  Alcotest.(check bool) "an advisory finding never fails --strict" false
    (List.exists Lint.fails_strict shell)

(* Every rule in the catalog has a distinct code, so a message can always be
   traced back to the reference entry that documents it. *)
let test_registry_codes_unique () =
  let codes = List.map (fun (r : Lint_rules.rule) -> r.Lint_rules.code) Lint_rules.all in
  let sorted = List.sort compare codes in
  let rec dup = function
    | a :: (b :: _ as tl) -> if a = b then Some a else dup tl
    | _ -> None
  in
  (match dup sorted with
   | Some c -> Alcotest.failf "duplicate rule code: %s" c
   | None -> ());
  List.iter (fun c ->
    match Lint_rules.of_code c with
    | Some _ -> ()
    | None -> Alcotest.failf "code %s does not round-trip to a rule" c) codes

(* ── The stdlib is the audience's example ────────────────────────────────── *)

(* Rules that the standard library itself violates are rules nobody will
   believe. This is what caught FS.rename's old_/new_ parameters. *)
let test_stdlib_is_clean () =
  let dir = "../stdlib" in
  if not (Sys.file_exists dir) then
    Alcotest.failf "stdlib not found at %s (relative to test sandbox)" dir
  else
    Array.iter (fun name ->
      if Filename.check_suffix name ".wand" then begin
        let src = In_channel.with_open_text (Filename.concat dir name) In_channel.input_all in
        match Runner.lint_module_source src with
        | Error m -> Alcotest.failf "%s failed to lint: %s" name m
        | Ok [] -> ()
        | Ok fs ->
          Alcotest.failf "%s has lint findings:\n%s" name
            (String.concat "\n" (List.map Lint.to_text fs))
      end
    ) (Sys.readdir dir)

(* Everything else written in wand: the tests, the demos, the examples, and
   wand's own CI script. The stdlib check above covered the library only, so
   a manifest permitting what a test file did not use, or a function that
   could raise without saying so, sat there warning and nothing failed. Eleven
   of them had, across files nobody had linted since writing them.

   The exceptions are demo files that are supposed to be wrong: a demo whose
   point is an error has to contain one, and each of these is asserted by its
   own run.sh. *)
let expected_findings =
  [ ("backup.wand", "A-USES2"); ("backup-phoning-home.wand", "A-USES2") ]

let expected_type_errors =
  [ (* D1: the same script bash would run, which wand will not. *)
    "unsafe.wand";
    (* D4: a manifest narrower than the code, which is the demo. *)
    "backup-bounded.wand" ]

let rec wand_files dir =
  Sys.readdir dir |> Array.to_list
  |> List.concat_map (fun entry ->
       let path = Filename.concat dir entry in
       if Sys.is_directory path then wand_files path
       else if Filename.check_suffix entry ".wand" then [ path ]
       else [])

let test_corpus_is_clean () =
  let roots = List.filter Sys.file_exists [ "wand"; "../demos"; "../examples"; "../ci" ] in
  let files = List.concat_map wand_files roots in
  Alcotest.(check bool) "found files to lint" true (List.length files > 20);
  List.iter
    (fun path ->
      let name = Filename.basename path in
      match Runner.typecheck_file path with
      | Error _ when List.mem name expected_type_errors -> ()
      | Error m -> Alcotest.failf "%s failed to typecheck: %s" path m
      | Ok (_, _, findings) ->
        let unexpected =
          List.filter
            (fun (f : Lint.finding) ->
              not (List.mem (name, Lint_rules.code f.Lint.rule) expected_findings))
            findings
        in
        if unexpected <> [] then
          Alcotest.failf "%s has lint findings:\n%s" path
            (String.concat "\n" (List.map Lint.to_text unexpected)))
    files

(* The same modules through the path a person uses. `lint_module_source`
   above is the library call; this is `wand t --file`, which has to reach
   them too -- a module body calls the raw builtins, and checked as a script
   it fails on the first one. Without this the standard library could only
   be checked by importing it, so a module could go wrong in a way nobody
   would see until something used it. *)
let test_stdlib_typechecks_through_the_tool () =
  let dir = "../stdlib" in
  if not (Sys.file_exists dir) then
    Alcotest.failf "stdlib not found at %s (relative to test sandbox)" dir
  else
    Array.iter (fun name ->
      if Filename.check_suffix name ".wand" then
        match Runner.typecheck_file (Filename.concat dir name) with
        | Error m -> Alcotest.failf "%s does not typecheck as a module: %s" name m
        | Ok (_, _, []) -> ()
        | Ok (_, _, fs) ->
          Alcotest.failf "%s has findings:\n%s" name
            (String.concat "\n" (List.map Lint.to_text fs))
    ) (Sys.readdir dir)

(* And the boundary the same rule protects: a script cannot reach past a
   module to the builtin underneath it. *)
let test_a_script_cannot_call_builtins () =
  match Runner.run_string "fs_temp_file \"x\" \".txt\"" with
  | Error _ -> ()
  | Ok s -> Alcotest.failf "a script reached a raw builtin, got: %s" s

(* ── The doc/lint bridge ─────────────────────────────────────────────────── *)

(* A rule the reference does not document is a rule its audience cannot look
   up; an ID the reference cites that no longer exists sends them looking for
   something gone. Both directions are checked, because prose and enforcement
   drifting apart is exactly what rule IDs exist to prevent. *)
(* ── The stdlib the tools know about ─────────────────────────────────────── *)

(* `stdlib_module_names` drives which modules `wand d` will import to answer
   about, which `wand env` lists, and which unknown name gets "did you forget
   to import". A module on disk but missing from the list still imports and
   runs -- it just goes invisible to the tools. `Test` sat that way with
   unreachable doc strings until someone asked `wand d` about it. *)
let test_every_stdlib_module_is_listed () =
  let dir = "../stdlib" in
  if not (Sys.file_exists dir) then
    Alcotest.failf "stdlib not found at %s (relative to test sandbox)" dir;
  let on_disk =
    Sys.readdir dir
    |> Array.to_list
    |> List.filter_map (fun f ->
         if Filename.check_suffix f ".wand" then Some (Filename.remove_extension f) else None)
    |> List.sort compare
  in
  let listed = List.sort compare Wand.Typechecker.stdlib_module_names in
  let missing = List.filter (fun m -> not (List.mem m listed)) on_disk in
  let extra   = List.filter (fun m -> not (List.mem m on_disk)) listed in
  if missing <> [] then
    Alcotest.failf "on disk but not in stdlib_module_names: %s" (String.concat ", " missing);
  if extra <> [] then
    Alcotest.failf "in stdlib_module_names but not on disk: %s" (String.concat ", " extra)

let reference_path = "../docs/reference.md"

let reference_text () =
  if not (Sys.file_exists reference_path) then
    Alcotest.failf "reference not found at %s (relative to test sandbox)" reference_path;
  In_channel.with_open_text reference_path In_channel.input_all

let contains hay nee =
  let hn = String.length hay and nn = String.length nee in
  if nn > hn then false
  else begin
    let found = ref false in
    for i = 0 to hn - nn do
      if String.sub hay i nn = nee then found := true
    done; !found
  end

let test_every_rule_is_documented () =
  let text = reference_text () in
  List.iter (fun (r : Lint_rules.rule) ->
    if not (contains text r.Lint_rules.code) then
      Alcotest.failf "rule %s is not documented in %s" r.Lint_rules.code reference_path
  ) Lint_rules.all

let test_every_documented_id_exists () =
  let text = reference_text () in
  (* Every M-/H- token in the reference must name a rule in the catalog. *)
  let n = String.length text in
  let i = ref 0 in
  while !i < n - 1 do
    if (text.[!i] = 'M' || text.[!i] = 'H') && text.[!i + 1] = '-' then begin
      let j = ref (!i + 2) in
      while !j < n && (let c = text.[!j] in
                       (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) do incr j done;
      let code = String.sub text !i (!j - !i) in
      if String.length code > 2 && Lint_rules.of_code code = None then
        Alcotest.failf "%s cites rule %s, which is not in the catalog"
          reference_path code;
      i := !j
    end else incr i
  done

let () =
  Alcotest.run "Lint" [
    "rules", [
      Alcotest.test_case "V-PRED1"  `Quick test_pred1;
      Alcotest.test_case "V-PRED2"  `Quick test_pred2;
      Alcotest.test_case "V-OR1"    `Quick test_or1;
      Alcotest.test_case "V-NAME1"  `Quick test_name1;
      Alcotest.test_case "V-DROP1"  `Quick test_drop1;
      Alcotest.test_case "A-SHELL1" `Quick test_shell1;
      Alcotest.test_case "A-USES1"  `Quick test_uses1;
      Alcotest.test_case "A-USES2"  `Quick test_uses2;
    ];
    "catalog", [
      Alcotest.test_case "kinds"        `Quick test_kinds;
      Alcotest.test_case "unique codes" `Quick test_registry_codes_unique;
    ];
    "stdlib", [
      Alcotest.test_case "lints clean" `Quick test_stdlib_is_clean;
      Alcotest.test_case "the corpus lints clean" `Quick test_corpus_is_clean;
      Alcotest.test_case "checks through the tool" `Quick test_stdlib_typechecks_through_the_tool;
      Alcotest.test_case "scripts cannot call builtins" `Quick test_a_script_cannot_call_builtins;
    ];
    "reference", [
      Alcotest.test_case "documents every rule" `Quick test_every_rule_is_documented;
      Alcotest.test_case "cites only real rules" `Quick test_every_documented_id_exists;
    ];
    "module list", [
      Alcotest.test_case "matches the stdlib directory" `Quick test_every_stdlib_module_is_listed;
    ];
  ]
