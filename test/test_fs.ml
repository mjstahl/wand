open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

let err label input =
  match run input with
  | Error _ -> ()
  | Ok v -> Alcotest.failf "%s: expected error but got: %s" label v

(* Trust anchor for test/wand/fs_test.wand: verifies FS.write_file/
   read_file round-trip against a real, OCaml-managed temp file. Every
   other FS.wand fixture test builds on this to create/read its own
   scratch files without needing OCaml-side scaffolding. *)
let test_read_write_round_trip () =
  let tmp = Filename.temp_file "wand_test_" ".txt" in
  let src = Printf.sprintf
    {|import FS
import Path
let () = FS.write_file "%s" "hello world"
FS.read_file "%s"|} tmp tmp in
  (try ok "write_file then read_file round-trips" src "hello world"
   with e -> (try Sys.remove tmp with _ -> ()); raise e);
  (try Sys.remove tmp with _ -> ())

(* These are type errors, so the whole file fails to typecheck before any
   test runs -- they can't be expressed as wand-native Test.wand cases,
   which only isolate runtime failures within an otherwise well-typed
   file. *)
let test_type_errors () =
  err "read_file non-string"      {|import FS
FS.read_file 42|};
  err "write_file non-string arg" {|import FS
FS.write_file 42 "content"|}

(* ── Suite ─────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "FS" [
    "real", [
      Alcotest.test_case "read/write round trip" `Quick test_read_write_round_trip;
    ];
    "errors", [
      Alcotest.test_case "type errors" `Quick test_type_errors;
    ];
  ]
