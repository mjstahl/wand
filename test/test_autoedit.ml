open Wand

(* The lexical tier as a pure function: buffer text in, edits out. Each
   deliberate limit in LSP.md §2.1 gets a case, because those limits are
   the judgments a future change is most likely to erode by accident. *)

let show = function
  | Autoedit.Insert_line (n, s) -> Printf.sprintf "+%d:%s" n s
  | Autoedit.Replace_line (n, s) -> Printf.sprintf "=%d:%s" n s

let check_edits name expected edits =
  Alcotest.(check (list string)) name expected (List.map show edits)

(* A signature table the test controls: `FS.write_file!` commits a file to
   FS.Write, `Sh.run!` to Shell, `List.map` to nothing. *)
let scheme_with labels =
  Typechecker.Mono
    (Typechecker.TFun (Typechecker.TString, Typechecker.TString,
                       Effect_row.of_list labels))

let fake_sig = function
  | "FS" -> Some ([("write_file!", scheme_with [Effect_row.FsWrite; Effect_row.Raise])], [])
  | "Sh" -> Some ([("run!", scheme_with [Effect_row.Shell; Effect_row.Raise])], [])
  | "List" -> Some ([("map", scheme_with [])], [])
  | _ -> None

let changes = Autoedit.changes ~sig_of:fake_sig

(* ── The demo moment ─────────────────────────────────────────────────────── *)

let test_import_and_manifest () =
  check_edits "import inserted, manifest extended"
    ["+3:import FS"; "=1:uses {FS.Write, IO}"]
    (changes
       ~old_text:"uses {IO}\n\nFS.write_file!"
       "uses {IO}\n\nFS.write_file! ")

let test_no_refire () =
  check_edits "an unchanged reference set fires nothing" []
    (changes
       ~old_text:"uses {IO}\n\nFS.write_file! "
       "uses {IO}\n\nFS.write_file! /tmp/x ")

(* An undo of the applyEdit removes the import but not the reference, so
   the next change must not re-insert it against the author's decision. *)
let test_undo_respected () =
  check_edits "undo does not re-fire" []
    (changes
       ~old_text:"uses {IO}\n\nFS.write_file! \n"
       "uses {IO}\n\nFS.write_file! x\n")

(* ── The trigger ─────────────────────────────────────────────────────────── *)

let test_incomplete_name_waits () =
  check_edits "no following character: still typing" []
    (changes ~old_text:"uses {IO}\n" "uses {IO}\nFS.write_file!")

let test_unresolved_member_never_edits () =
  check_edits "FS.nope: diagnostic territory, not an edit" []
    (changes ~old_text:"" "FS.nope ")

let test_unknown_module () =
  check_edits "not a stdlib module" []
    (changes ~old_text:"" "Zzz.foo ")

let test_bound_namespace () =
  check_edits "already imported: nothing to do" []
    (changes ~old_text:"import FS\n" "import FS\nFS.write_file! ")

let test_comments_and_strings_never_trigger () =
  check_edits "references in comments and strings are not code" []
    (changes ~old_text:""
       "-- FS.write_file! here\n(* List.map too *)\nlet s = \"FS.write_file! \"\ns\n")

(* ── The Shell rule ──────────────────────────────────────────────────────── *)

let test_shell_label_stays_out () =
  check_edits "import lands, Shell label goes to the quick fix"
    ["+2:import Sh"]
    (changes ~old_text:"uses {IO}\n" "uses {IO}\nSh.run! ")

let test_shell_binaries_preserved () =
  check_edits "extending around Shell(git) leaves the allowlist alone"
    ["+2:import FS"; "=1:uses {FS.Write, Shell(git)}"]
    (changes ~old_text:"uses {Shell(git)}\n" "uses {Shell(git)}\nFS.write_file! ")

(* ── The manifest rule ───────────────────────────────────────────────────── *)

let test_never_creates_a_manifest () =
  check_edits "no uses line: import only"
    ["+1:import FS"]
    (changes ~old_text:"" "FS.write_file! ")

let test_pure_member_leaves_manifest () =
  check_edits "List.map commits the manifest to nothing"
    ["+2:import List"]
    (changes ~old_text:"uses {IO}\nprintln \"x\"\n"
       "uses {IO}\nprintln \"x\"\nList.map ")

let test_trailing_comment_survives () =
  check_edits "text after the closing brace stays"
    ["+2:import FS"; "=1:uses {FS.Write, IO} -- why"]
    (changes ~old_text:"uses {IO} -- why\n" "uses {IO} -- why\nFS.write_file! ")

(* ── Insertion position ──────────────────────────────────────────────────── *)

let test_sorted_insertion () =
  check_edits "keeps a sorted block sorted"
    ["+3:import List"]
    (changes ~old_text:"import FS\nimport JSON\n\n"
       "import FS\nimport JSON\n\nList.map ")

let test_insert_at_block_head () =
  check_edits "a name before the block goes first"
    ["+1:import FS"]
    (changes ~old_text:"import JSON\nimport List\n\n"
       "import JSON\nimport List\n\nFS.write_file! ")

let test_block_after_manifest_blank () =
  (* No block yet: the line lands where the block canonically starts,
     after the manifest and the blank that follows it. *)
  check_edits "block created below the manifest"
    ["+3:import List"]
    (changes ~old_text:"uses {IO}\n\nprintln \"x\"\n"
       "uses {IO}\n\nprintln \"x\"\nList.map ")

let test_shebang_respected () =
  check_edits "import goes below the shebang"
    ["+2:import List"]
    (changes ~old_text:"#!/usr/bin/env wand\n" "#!/usr/bin/env wand\nList.map ")

(* ── Against the real standard library ────────────────────────────────────── *)

let test_real_stdlib () =
  check_edits "FS.write_file! against the embedded library"
    ["+3:import FS"; "=1:uses {FS.Write, IO}"]
    (Autoedit.changes ~sig_of:Runner.stdlib_module_sig
       ~old_text:"uses {IO}\n\nFS.write_file!"
       "uses {IO}\n\nFS.write_file! ")

let () =
  Alcotest.run "autoedit" [
    "trigger", [
      Alcotest.test_case "import and manifest"  `Quick test_import_and_manifest;
      Alcotest.test_case "no refire"            `Quick test_no_refire;
      Alcotest.test_case "undo respected"       `Quick test_undo_respected;
      Alcotest.test_case "incomplete waits"     `Quick test_incomplete_name_waits;
      Alcotest.test_case "unresolved member"    `Quick test_unresolved_member_never_edits;
      Alcotest.test_case "unknown module"       `Quick test_unknown_module;
      Alcotest.test_case "bound namespace"      `Quick test_bound_namespace;
      Alcotest.test_case "comments and strings" `Quick test_comments_and_strings_never_trigger;
    ];
    "shell", [
      Alcotest.test_case "label stays out"      `Quick test_shell_label_stays_out;
      Alcotest.test_case "binaries preserved"   `Quick test_shell_binaries_preserved;
    ];
    "manifest", [
      Alcotest.test_case "never created"        `Quick test_never_creates_a_manifest;
      Alcotest.test_case "pure member"          `Quick test_pure_member_leaves_manifest;
      Alcotest.test_case "trailing comment"     `Quick test_trailing_comment_survives;
    ];
    "position", [
      Alcotest.test_case "sorted insertion"     `Quick test_sorted_insertion;
      Alcotest.test_case "block head"           `Quick test_insert_at_block_head;
      Alcotest.test_case "after manifest"       `Quick test_block_after_manifest_blank;
      Alcotest.test_case "shebang"              `Quick test_shebang_respected;
    ];
    "stdlib", [
      Alcotest.test_case "real signatures"      `Quick test_real_stdlib;
    ];
  ]
