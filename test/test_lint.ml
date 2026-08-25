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

(* Two imports fighting over one name leave the first binding dead and
   misstate where the name comes from. Renaming one binding keeps both, so
   that's what the message suggests. *)
let test_imp1 () =
  fires "the same name from two modules"
    "let {parse} = import JSON\nlet {parse} = import TOML\nparse \"x = 1\""
    "V-IMP1";
  silent "renamed apart"
    "let {parse = jparse} = import JSON\nlet {parse = tparse} = import TOML\n\
     let _ = jparse \"1\"\ntparse \"x = 1\"";
  (* A use between the two imports reads the *second* one, because imports
     bind before the file's own bindings wherever they are written. So the
     first binding is dead there too, and the rule used to stop at the
     first non-import item and miss it. *)
  fires "a use between imports"
    "let {parse} = import JSON\nlet j = parse \"1\"\n\
     let {parse} = import TOML\nparse \"x = 1\""
    "V-IMP1";
  silent "two modules that share no name"
    "let {parse} = import JSON\nlet j = parse \"1\"\n\
     let {upper} = import String\nupper \"a\""

(* An import that binds nothing the file mentions. The fix deletes the line,
   so the rule stays silent whenever it cannot account for every name -- an
   import brings its module's types and constructors as well as the names it
   says, and which module a type came from is not in the file. *)

let test_imp2 () =
  fires "a namespace nothing calls"
    "uses {IO}\nimport IO\nimport List\nIO.println \"hi\""
    "V-IMP2";
  silent "one that is called"
    "uses {IO}\nimport IO\nimport List\nIO.println \"%{List.length [1]}\"";
  fires "a destructured name nothing uses"
    "import List\nlet {test} = import Test\nList.length [1]"
    "V-IMP2";
  silent "one that is used"
    "let {test} = import Test\ntest \"x\" (fn t -> t.eq 1 1)";
  (* Naming a built-in type is reading the language, not the module that
     used to declare it -- which is what four dead `import Option` lines in
     the standard library were hiding behind. *)
  fires "a module named only as a built-in type"
    "import Option\nimport List\nlet f (x: Option Int) = x\nList.length [1]"
    "V-IMP2";
  (* A type this file did not declare could have come from any of its
     imports, so none of them is reported. *)
  silent "a file that names a type it did not declare"
    "import Test\nimport List\ntype Run(outcome: TestOutcome)\n\
     Run(outcome = Pass \"x\")";
  silent "and a constructor it did not declare"
    "import Test\nimport List\nPass \"x\""

(* The civil clock steps, so the length between two readings of it is wrong
   or zero on the day it does. The rule catches the shape a script is
   written in -- save a reading, work, subtract -- as well as the inline
   one, and leaves alone the subtraction that is sound: an instant that came
   from somewhere else. *)
let test_clock1 () =
  fires "two readings inline"
    "uses {Clock}\nimport Clock\nClock.now () - Clock.now ()"
    "V-CLOCK1";
  fires "a reading saved and subtracted"
    "uses {Clock}\nimport Clock\n\
     let took = (let before = Clock.now () in Clock.now () - before)\ntook"
    "V-CLOCK1";
  silent "an age, which is what subtraction is for"
    "uses {Clock, FS.Read}\nimport Clock\nimport FS\n\
     Clock.now () - FS.mtime! /etc/hosts";
  silent "a name rebound to something else is not a reading"
    "uses {Clock, FS.Read}\nimport Clock\nimport FS\n\
     let t = (let before = Clock.now () in \
     let before = FS.mtime! /etc/hosts in Clock.now () - before)\nt";
  silent "measuring the way that works"
    "uses {Clock}\nimport Clock\nClock.timed (fn () -> 1 + 1)"

let test_pred1 () =
  fires "non-Bool predicate" "let big? n = n * 2\nbig? 3" "V-PRED1";
  silent "Bool predicate" "let big? n = n > 2\nbig? 3";
  (* The rule is one-directional: a Bool-returning function need not be `?`. *)
  silent "Bool without ?" "let positive n = n > 0\npositive 1"

(* A name takes one ending. `ok?!` and `ok!?` are both parse errors, so the
   advice for a predicate that raises cannot be to add the `!`, which is
   what it used to be -- a name the reader could not have written. *)
let test_bang1_on_a_predicate () =
  let msg src =
    match findings src with
    | [] -> Alcotest.fail "expected a finding"
    | fs ->
      (match List.find_opt
               (fun (f : Lint.finding) ->
                  Lint_rules.code f.Lint.rule = "V-BANG1") fs with
       | Some f -> f.Lint.text
       | None   -> Alcotest.fail "expected V-BANG1")
  in
  let m = msg "import List\nlet found? xs = List.head! xs\nfound? [1]" in
  if Lint.contains m "found?!" then
    Alcotest.failf "suggested a name that does not parse:\n%s" m;
  if not (Lint.contains m "found!") then
    Alcotest.failf "expected it to name the alternative:\n%s" m;
  (* The ordinary case keeps the ordinary advice. *)
  let plain = msg "import List\nlet first xs = List.head! xs\nfirst [1]" in
  if not (Lint.contains plain "first!") then
    Alcotest.failf "expected the plain suggestion:\n%s" plain

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

(* A test block answers with one outcome, so an assertion sequenced before
   another is thrown away and the test reports a pass however it went. The
   framework cannot notice -- the value is gone before it is asked for -- so
   the rule is the only thing between a green run and a lie. *)
let test_drop2 () =
  fires "an assertion discarded by `;`"
    "let {test} = import Test\ntest \"t\" (fn t -> (t.eq 1 2; t.eq 3 3))"
    "V-DROP2";
  (* Three or more: still one finding per discarded assertion, and the last
     one is the block's answer rather than a discard. *)
  fires "several discarded assertions"
    "let {test} = import Test\n\
     test \"t\" (fn t -> (t.ok true; t.ok false; t.eq 1 1))"
    "V-DROP2";
  (* The ordinary shape: one assertion, returned. *)
  silent "a single assertion"
    "let {test} = import Test\ntest \"t\" (fn t -> t.eq 3 (1 + 2))";
  (* A top-level `test` statement is discarded too, but the runner collects
     those -- that is how the framework is used, not a mistake. *)
  silent "top-level test statements"
    "let {test} = import Test\n\
     test \"a\" (fn t -> t.ok true)\ntest \"b\" (fn t -> t.ok true)";
  (* The remedy the message names has to lint clean, or it is not a remedy. *)
  silent "assertions split across a group"
    "let {test, group} = import Test\n\
     group \"g\" (fn () -> let n = 6 * 7 in [\n\
     test \"a\" (fn t -> t.eq 42 n),\n\
     test \"b\" (fn t -> t.ok (n > 0))])";
  (* Setup before the assertion is ordinary sequencing, not a discard: only
     a discarded TestOutcome is worth a finding. *)
  silent "a non-assertion statement before the assertion"
    "uses {IO}\nlet {test} = import Test\nimport IO\n\
     test \"t\" (fn t -> (IO.println \"setting up\"; t.ok true))"

(* A narrowed Shell with a command word only the run decides: legal, said
   out loud, and an error under --strict. *)
let test_shell1_dynamic () =
  fires "interpolated word under a narrowed manifest"
    "uses {Shell(git), IO}\nimport IO\nlet c = \"git\"\nIO.println $(%!{c} status)"
    "V-SHELL1";
  silent "interpolated word under bare Shell"
    "uses {Shell, IO}\nimport IO\nlet c = \"git\"\nIO.println $(%!{c} status)";
  silent "literal words under a narrowed manifest"
    "uses {Shell(git), IO}\nimport IO\nIO.println $(git status)"

(* Shell(...) entries have the same accounting as effect labels: one no
   command position runs is flagged -- but only when every position is
   literal, because an interpolated one may be exactly where the
   unused-looking binary is spawned. *)
let test_uses1_shell_binaries () =
  fires "an allowlisted binary nothing runs"
    "uses {Shell(git, curl)}\nlet b = $(git status)\nb"
    "A-USES1";
  silent "all binaries earn their place"
    "uses {Shell(git)}\nlet b = $(git status)\nb";
  (let got =
     codes "uses {Shell(git, curl)}\nlet b c = $(%!{c} x)\nb \"git\"" in
   if List.mem "A-USES1" got then
     Alcotest.failf
       "a dynamic site must suspend the unused-binary judgment, got [%s]"
       (String.concat "; " got))

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
      | Error d -> Alcotest.failf "%s failed to typecheck: %s" path (Diag.legacy d)
      | Ok sc ->
        let findings = sc.Runner.sc_findings in
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
        | Error d -> Alcotest.failf "%s does not typecheck as a module: %s" name (Diag.legacy d)
        | Ok { Runner.sc_findings = []; _ } -> ()
        | Ok sc ->
          Alcotest.failf "%s has findings:\n%s" name
            (String.concat "\n" (List.map Lint.to_text sc.Runner.sc_findings))
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
   about, which `wand v` lists, and which unknown name gets "did you forget
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
  (* Every V-/A- token in the reference must name a rule in the catalog. *)
  let n = String.length text in
  let i = ref 0 in
  while !i < n - 1 do
    if (text.[!i] = 'V' || text.[!i] = 'A') && text.[!i + 1] = '-' then begin
      let j = ref (!i + 2) in
      while !j < n && (let c = text.[!j] in
                       (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) do incr j done;
      let code = String.sub text !i (!j - !i) in
      (* A rule code ends in a number; prose ranges like `A-Z` do not. *)
      let ends_in_digit =
        String.length code > 0 &&
        (let c = code.[String.length code - 1] in c >= '0' && c <= '9')
      in
      if String.length code > 2 && ends_in_digit
         && Lint_rules.of_code code = None then
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
      Alcotest.test_case "V-BANG1 on a predicate" `Quick
        test_bang1_on_a_predicate;
      Alcotest.test_case "V-OR1"    `Quick test_or1;
      Alcotest.test_case "V-NAME1"  `Quick test_name1;
      Alcotest.test_case "V-DROP1"  `Quick test_drop1;
      Alcotest.test_case "V-DROP2"  `Quick test_drop2;
      Alcotest.test_case "V-IMP1"   `Quick test_imp1;
      Alcotest.test_case "V-IMP2"   `Quick test_imp2;
      Alcotest.test_case "V-CLOCK1" `Quick test_clock1;
      Alcotest.test_case "A-SHELL1" `Quick test_shell1;
      Alcotest.test_case "A-USES1"  `Quick test_uses1;
      Alcotest.test_case "A-USES1 binaries" `Quick test_uses1_shell_binaries;
      Alcotest.test_case "A-USES2"  `Quick test_uses2;
      Alcotest.test_case "V-SHELL1" `Quick test_shell1_dynamic;
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
