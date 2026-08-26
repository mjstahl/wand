open Wand

(* `wand t --fix` at the engine level: source in, fixed source and the
   applied set out. The same fixes feed the editor's code actions, so what
   these tests lock is the one behavior both consumers share. *)

let fix src =
  match Fix.fix_source ~path:"wand_fix_test.wand" src with
  | Ok (fixed, applied) -> (fixed, applied)
  | Error d -> Alcotest.failf "expected fixes, got refusal: %s" (Diag.legacy d)

let refuse src =
  match Fix.fix_source ~path:"wand_fix_test.wand" src with
  | Error d -> d
  | Ok (fixed, _) -> Alcotest.failf "expected a refusal, got:\n%s" fixed

let codes applied = List.map (fun a -> a.Fix.code) applied

let test_manifest_created () =
  let (fixed, applied) =
    fix "import FS\nlet f p = FS.write_file p \"x\"\nf /tmp/y\n" in
  Alcotest.(check string) "manifest inserted first"
    "uses {FS.Write}\nimport FS\nlet f p = FS.write_file p \"x\"\nf /tmp/y\n"
    fixed;
  Alcotest.(check (list string)) "one A-USES2" ["A-USES2"] (codes applied)

let test_manifest_after_shebang () =
  let (fixed, _) =
    fix "#!/usr/bin/env wand\nimport FS\nFS.write_file /tmp/x.txt \"hi\"\n" in
  Alcotest.(check string) "shebang stays first"
    "#!/usr/bin/env wand\nuses {FS.Write}\nimport FS\nFS.write_file /tmp/x.txt \"hi\"\n"
    fixed

let test_manifest_widened () =
  (* The manifest type error's suggestion, applied from its structured
     fix rather than its prose. *)
  let (fixed, applied) =
    fix "uses {FS.Read}\nimport FS\nFS.write_file /tmp/x.txt \"hi\"\n" in
  Alcotest.(check string) "manifest replaced"
    "uses {FS.Write}\nimport FS\nFS.write_file /tmp/x.txt \"hi\"\n" fixed;
  Alcotest.(check (list string)) "via the E-TYPE fix" ["E-TYPE"] (codes applied)

let test_manifest_narrowed () =
  let (fixed, applied) =
    fix "uses {Shell, FS.Write}\nimport FS\nlet f p = FS.write_file p \"x\"\nf /tmp/y\n" in
  Alcotest.(check string) "unused label dropped"
    "uses {FS.Write}\nimport FS\nlet f p = FS.write_file p \"x\"\nf /tmp/y\n" fixed;
  Alcotest.(check (list string)) "via A-USES1" ["A-USES1"] (codes applied)

(* Widening the Shell list to admit the new word unlocks A-USES1 for the
   binary the file never runs -- the fixed point takes two passes, and the
   engine must find the manifest line even though the shell-word error
   points at the $() that tripped it. *)
let test_shell_fixed_point () =
  let (fixed, applied) =
    fix "uses {Shell(git)}\nlet v = $(curl -s https://x.dev)\nv\n" in
  Alcotest.(check string) "widened, then narrowed"
    "uses {Shell(curl)}\nlet v = $(curl -s https://x.dev)\nv\n" fixed;
  Alcotest.(check (list string)) "both passes reported"
    ["E-TYPE"; "A-USES1"] (codes applied)

let test_dead_import_deleted () =
  let (fixed, applied) =
    fix "let {parse} = import CSV\nlet {parse} = import TOML\nparse \"x = 1\"\n" in
  Alcotest.(check string) "first binding gone"
    "let {parse} = import TOML\nparse \"x = 1\"\n" fixed;
  Alcotest.(check bool) "V-IMP1 among the fixes" true
    (List.mem "V-IMP1" (codes applied))

let test_nothing_to_fix () =
  let src = "let double x = x * 2\ndouble 21\n" in
  let (fixed, applied) = fix src in
  Alcotest.(check string) "unchanged" src fixed;
  Alcotest.(check int) "nothing applied" 0 (List.length applied)

(* A finding without a machine-applicable fix is reported by `wand t` but
   is none of --fix's business. *)
let test_unfixable_finding_left_alone () =
  let src = "let ready? x = x + 1\nready? 2\n" in
  let (fixed, applied) = fix src in
  Alcotest.(check string) "unchanged" src fixed;
  Alcotest.(check int) "nothing applied" 0 (List.length applied)

let test_refuses_parse_error () =
  let d = refuse "let x = (1\n" in
  Alcotest.(check string) "the parse error is reported" "E-PARSE" d.Diag.code

(* A missing import is a correction the checker already knows: the error
   names the module, so the fix is the line the file lacks. *)

let test_import_inserted () =
  let (fixed, applied) = fix "uses {IO}\n\nlet () = IO.println \"hi\"\n" in
  Alcotest.(check string) "under the manifest, with the blank line"
    "uses {IO}\n\nimport IO\n\nlet () = IO.println \"hi\"\n" fixed;
  Alcotest.(check (list string)) "one E-TYPE" ["E-TYPE"] (codes applied)

let test_import_joins_the_run () =
  let src =
    "uses {IO}\nimport IO\nimport Path\n\n     let n = List.length [Path.of_string \"a\"]\nIO.println \"%{n}\"\n" in
  let (fixed, _) = fix src in
  Alcotest.(check string) "in the order the run is kept"
    "uses {IO}\nimport IO\nimport List\nimport Path\n\n     let n = List.length [Path.of_string \"a\"]\nIO.println \"%{n}\"\n"
    fixed

let test_import_before_destructured () =
  let (fixed, _) =
    fix "let {test} = import Test\n\ntest \"x\" (fn t -> t.eq 1 (List.length [1]))\n" in
  Alcotest.(check string) "a plain import goes above a destructured one"
    "import List\n\nlet {test} = import Test\n\ntest \"x\" (fn t -> t.eq 1 (List.length [1]))\n"
    fixed

let test_imports_to_a_fixed_point () =
  let (_, applied) =
    fix "uses {IO}\n\nlet () = IO.println \"%{List.length (Map.keys {a = 1})}\"\n" in
  Alcotest.(check int) "one per pass, three passes" 3 (List.length applied)

let test_refuses_unfixable_type_error () =
  let d = refuse "let x = 1 + true\nx\n" in
  Alcotest.(check string) "the type error is reported" "E-TYPE" d.Diag.code

(* ── A constructor that swallowed an argument ────────────────────────────── *)

(* Parentheses after a constructor are its payload, so `f None (1)` is
   `f (None 1)` and a nullary constructor has taken the argument meant for
   the call. The checker knew the arity and said what to write; now it hands
   over the correction as well, over the constructor's own extent. *)
let test_bare_constructor_bracketed () =
  let (fixed, applied) =
    fix "type Opt = None | Some Int\nlet f a b = b\nlet r = f None (1)\n" in
  Alcotest.(check string) "the constructor is bracketed"
    "type Opt = None | Some Int\nlet f a b = b\nlet r = f (None) (1)\n" fixed;
  Alcotest.(check (list string)) "reported as a type error" ["E-TYPE"]
    (codes applied)

(* The name appears twice, and only the occurrence the extent covers is
   rewritten -- which is why the extent has to be the constructor's own
   rather than the statement's. *)
let test_only_the_flagged_occurrence () =
  let (fixed, _) =
    fix "type Opt = None | Some Int\nlet f a b = b\nlet g = None\nlet r = f None (1)\n" in
  Alcotest.(check string) "the bare None is untouched"
    "type Opt = None | Some Int\nlet f a b = b\nlet g = None\nlet r = f (None) (1)\n"
    fixed

(* A drift correction names its substitution in prose rather than spanning
   it, so it declines the same test and nothing is written on its behalf. *)
let test_drift_still_declines () =
  let d = refuse "let b = not true\n" in
  Alcotest.(check bool) "refused rather than rewritten" true
    (Lint.contains (Diag.legacy d) "boolean not is")

let () =
  Alcotest.run "fix" [
    "manifest", [
      Alcotest.test_case "created"        `Quick test_manifest_created;
      Alcotest.test_case "after shebang"  `Quick test_manifest_after_shebang;
      Alcotest.test_case "widened"        `Quick test_manifest_widened;
      Alcotest.test_case "narrowed"       `Quick test_manifest_narrowed;
      Alcotest.test_case "shell, 2 passes" `Quick test_shell_fixed_point;
    ];
    "findings", [
      Alcotest.test_case "dead import"    `Quick test_dead_import_deleted;
      Alcotest.test_case "clean file"     `Quick test_nothing_to_fix;
      Alcotest.test_case "no fix carried" `Quick test_unfixable_finding_left_alone;
    ];
    "imports", [
      Alcotest.test_case "inserted"       `Quick test_import_inserted;
      Alcotest.test_case "joins the run"  `Quick test_import_joins_the_run;
      Alcotest.test_case "above destructured" `Quick test_import_before_destructured;
      Alcotest.test_case "to a fixed point" `Quick test_imports_to_a_fixed_point;
    ];
    "a constructor that swallowed an argument", [
      Alcotest.test_case "bracketed"      `Quick test_bare_constructor_bracketed;
      Alcotest.test_case "only the flagged one" `Quick
        test_only_the_flagged_occurrence;
      Alcotest.test_case "drift declines" `Quick test_drift_still_declines;
    ];
    "refusals", [
      Alcotest.test_case "parse error"    `Quick test_refuses_parse_error;
      Alcotest.test_case "type error"     `Quick test_refuses_unfixable_type_error;
    ];
  ]
