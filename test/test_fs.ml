open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

(* Trust anchor for test/wand/test_fs.wand: verifies FS.write_file/
   read_file round-trip against a real, OCaml-managed temp file. Every
   other FS.wand fixture test builds on this to create/read its own
   scratch files without needing OCaml-side scaffolding. *)
let test_read_write_round_trip () =
  let tmp = Filename.temp_file "wand_test_" ".txt" in
  let src = Printf.sprintf
    {|import FS
import Path
let () = FS.write_file! (Path.of_string "%s") "hello world"
FS.read_file! (Path.of_string "%s")|} tmp tmp in
  (try ok "write_file then read_file round-trips" src "hello world"
   with e -> (try Sys.remove tmp with _ -> ()); raise e);
  (try Sys.remove tmp with _ -> ())

(* ── Suite ─────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "FS" [
    "real", [
      Alcotest.test_case "read/write round trip" `Quick test_read_write_round_trip;
    ];
  ]
