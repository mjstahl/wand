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
  fires "non-Bool predicate" "let big? n = n * 2\nbig? 3" "M-PRED1";
  silent "Bool predicate" "let big? n = n > 2\nbig? 3";
  (* The rule is one-directional: a Bool-returning function need not be `?`. *)
  silent "Bool without ?" "let positive n = n > 0\npositive 1"

let test_or1 () =
  fires "Result with a Unit error" "let f x : Result Unit Int = Ok x\nf 1" "M-OR1";
  silent "Result with a reason" "let f x : Result String Int = Ok x\nf 1"

let test_name1 () =
  fires "trailing-underscore parameter" "let rename old_ new_ = old_ ++ new_\nrename \"a\" \"b\""
    "M-NAME1";
  silent "ordinary parameters" "let rename src dst = src ++ dst\nrename \"a\" \"b\"";
  (* A bare `_` is a wildcard, not an escaped name. *)
  silent "wildcard parameter" "let f _ = 1\nf 2"

let test_shell1 () =
  fires "multi-stage pipeline"
    "let c = $(git log --oneline | grep fix | wc -l | tr -d \" \")\nc" "H-SHELL1";
  silent "single command" "let c = $(git status)\nc";
  silent "one pipe" "let c = $(ls | wc -l)\nc"

(* ── Classification ──────────────────────────────────────────────────────── *)

(* Only mechanical rules may fail a build: a heuristic that fires on correct
   code would teach its audience to ignore every rule beside it. *)
let test_kinds () =
  Alcotest.(check bool) "W-PRED1 is mechanical" true
    (Lint_rules.kind Lint_rules.M_PRED1 = Lint_rules.Mechanical);
  Alcotest.(check bool) "W-SHELL1 is heuristic" true
    (Lint_rules.kind Lint_rules.H_SHELL1 = Lint_rules.Heuristic);
  let shell = findings "let c = $(a | b | c | d)\nc" in
  Alcotest.(check bool) "a heuristic finding never fails --strict" false
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

let () =
  Alcotest.run "Lint" [
    "rules", [
      Alcotest.test_case "M-PRED1"  `Quick test_pred1;
      Alcotest.test_case "M-OR1"    `Quick test_or1;
      Alcotest.test_case "M-NAME1"  `Quick test_name1;
      Alcotest.test_case "H-SHELL1" `Quick test_shell1;
    ];
    "catalog", [
      Alcotest.test_case "kinds"        `Quick test_kinds;
      Alcotest.test_case "unique codes" `Quick test_registry_codes_unique;
    ];
    "stdlib", [
      Alcotest.test_case "lints clean" `Quick test_stdlib_is_clean;
    ];
  ]
