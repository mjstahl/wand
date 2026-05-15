open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

let err label input =
  match run input with
  | Error _ -> ()
  | Ok v -> Alcotest.failf "%s: expected error but got: %s" label v

(* ── mkdir ──────────────────────────────────────────────────────────────────── *)

let test_mkdir () =
  let tmp = Filename.temp_file "wand_test_" "" in
  Sys.remove tmp;
  let dir = tmp ^ "/nested/deep" in
  let src = Printf.sprintf
    {|import FS
import Path
let () = FS.mkdir (Path.of_string "%s")
"ok"|} dir in
  ok "mkdir -p" src "ok";
  assert (Sys.file_exists dir && Sys.is_directory dir);
  Unix.rmdir dir;
  Unix.rmdir (Filename.dirname dir);
  Unix.rmdir tmp

(* ── append ─────────────────────────────────────────────────────────────────── *)

let test_append_real () =
  let tmp = Filename.temp_file "wand_test_" ".txt" in
  let src = Printf.sprintf
    {|import FS
import Path
let p = Path.of_string "%s"
let () = FS.write_file "%s" "hello"
let () = FS.append p " world"
FS.read_file "%s"|} tmp tmp tmp in
  (try ok "append" src "hello world"
   with e -> (try Sys.remove tmp with _ -> ()); raise e);
  (try Sys.remove tmp with _ -> ())

(* ── create_file ────────────────────────────────────────────────────────────── *)

let test_create_file () =
  let tmp = Filename.temp_file "wand_test_" ".txt" in
  Sys.remove tmp;
  let src = Printf.sprintf
    {|import FS
import Path
let p = Path.of_string "%s"
let () = FS.create_file p
FS.read_file "%s"|} tmp tmp in
  (try ok "create_file" src ""
   with e -> (try Sys.remove tmp with _ -> ()); raise e);
  (try Sys.remove tmp with _ -> ())

(* ── rename ─────────────────────────────────────────────────────────────────── *)

let test_rename () =
  let tmp = Filename.temp_file "wand_test_" ".txt" in
  let dst = tmp ^ ".renamed" in
  Out_channel.with_open_text tmp (fun oc -> Out_channel.output_string oc "data");
  let src = Printf.sprintf
    {|import FS
import Path
let () = FS.rename (Path.of_string "%s") (Path.of_string "%s")
FS.read_file "%s"|} tmp dst dst in
  (try ok "rename" src "data"
   with e ->
     (try Sys.remove tmp with _ -> ());
     (try Sys.remove dst with _ -> ());
     raise e);
  (try Sys.remove dst with _ -> ())

(* ── copy ───────────────────────────────────────────────────────────────────── *)

let test_copy () =
  let src_file = Filename.temp_file "wand_test_" ".txt" in
  let dst_file = src_file ^ ".copy" in
  Out_channel.with_open_text src_file (fun oc ->
    Out_channel.output_string oc "copied");
  let src = Printf.sprintf
    {|import FS
import Path
let () = FS.copy (Path.of_string "%s") (Path.of_string "%s")
FS.read_file "%s"|} src_file dst_file dst_file in
  (try ok "copy" src "copied"
   with e ->
     (try Sys.remove src_file with _ -> ());
     (try Sys.remove dst_file with _ -> ());
     raise e);
  (try Sys.remove src_file with _ -> ());
  (try Sys.remove dst_file with _ -> ())

(* ── cwd / cd ───────────────────────────────────────────────────────────────── *)

let test_cwd () =
  let expected = Sys.getcwd () in
  let src = {|import FS
import Path
Path.to_string (FS.cwd ())|} in
  ok "cwd returns current dir" src expected

(* ── exists? / is_file? / is_dir? ───────────────────────────────────────────── *)

let test_exists () =
  let tmp = Filename.temp_file "wand_test_" ".txt" in
  let src = Printf.sprintf
    {|import FS
import Path
let p = Path.of_string "%s"
(FS.exists? p, FS.is_file? p, FS.is_dir? p)|} tmp in
  (try ok "exists/is_file/is_dir" src "(true, true, false)"
   with e -> (try Sys.remove tmp with _ -> ()); raise e);
  (try Sys.remove tmp with _ -> ())

(* ── size ───────────────────────────────────────────────────────────────────── *)

let test_size () =
  let tmp = Filename.temp_file "wand_test_" ".txt" in
  Out_channel.with_open_text tmp (fun oc ->
    Out_channel.output_string oc "12345");
  let src = Printf.sprintf
    {|import FS
import Path
FS.size (Path.of_string "%s")|} tmp in
  (try ok "size" src "5"
   with e -> (try Sys.remove tmp with _ -> ()); raise e);
  (try Sys.remove tmp with _ -> ())

(* ── list_dir ───────────────────────────────────────────────────────────────── *)

let test_list_dir () =
  let tmp_dir = Filename.temp_file "wand_test_dir_" "" in
  Sys.remove tmp_dir;
  Unix.mkdir tmp_dir 0o755;
  Out_channel.with_open_text (Filename.concat tmp_dir "a.txt") (fun oc ->
    Out_channel.output_string oc "a");
  Out_channel.with_open_text (Filename.concat tmp_dir "b.txt") (fun oc ->
    Out_channel.output_string oc "b");
  let src = Printf.sprintf
    {|import FS
import Path
import String
let entries = FS.list_dir (Path.of_string "%s")
String.join ", " (List.map Path.basename entries)|} tmp_dir in
  (try ok "list_dir" src "a.txt, b.txt"
   with e ->
     (try Sys.remove (Filename.concat tmp_dir "a.txt") with _ -> ());
     (try Sys.remove (Filename.concat tmp_dir "b.txt") with _ -> ());
     (try Unix.rmdir tmp_dir with _ -> ());
     raise e);
  (try Sys.remove (Filename.concat tmp_dir "a.txt") with _ -> ());
  (try Sys.remove (Filename.concat tmp_dir "b.txt") with _ -> ());
  (try Unix.rmdir tmp_dir with _ -> ())

(* ── walk ───────────────────────────────────────────────────────────────────── *)

let test_walk () =
  let tmp_dir = Filename.temp_file "wand_test_walk_" "" in
  Sys.remove tmp_dir;
  Unix.mkdir tmp_dir 0o755;
  let sub = Filename.concat tmp_dir "sub" in
  Unix.mkdir sub 0o755;
  Out_channel.with_open_text (Filename.concat tmp_dir "a.txt") (fun oc ->
    Out_channel.output_string oc "a");
  Out_channel.with_open_text (Filename.concat sub "b.txt") (fun oc ->
    Out_channel.output_string oc "b");
  let src = Printf.sprintf
    {|import FS
import Path
import String
let base = "%s/"
let entries = FS.walk (Path.of_string "%s")
let strip p =
  let s = Path.to_string p in
  String.slice (String.length base) (String.length s) s
String.join ", " (List.map strip entries)|} tmp_dir tmp_dir in
  (try ok "walk" src "a.txt, sub/b.txt"
   with e ->
     (try Sys.remove (Filename.concat tmp_dir "a.txt") with _ -> ());
     (try Sys.remove (Filename.concat sub "b.txt") with _ -> ());
     (try Unix.rmdir sub with _ -> ());
     (try Unix.rmdir tmp_dir with _ -> ());
     raise e);
  (try Sys.remove (Filename.concat tmp_dir "a.txt") with _ -> ());
  (try Sys.remove (Filename.concat sub "b.txt") with _ -> ());
  (try Unix.rmdir sub with _ -> ());
  (try Unix.rmdir tmp_dir with _ -> ())

(* ── delete ─────────────────────────────────────────────────────────────────── *)

let test_delete () =
  let tmp = Filename.temp_file "wand_test_" ".txt" in
  let src = Printf.sprintf
    {|import FS
import Path
let p = Path.of_string "%s"
let () = FS.delete p
FS.exists? p|} tmp in
  (try ok "delete" src "false"
   with e -> (try Sys.remove tmp with _ -> ()); raise e)

(* ── mock append ────────────────────────────────────────────────────────────── *)

let test_mock_append () =
  ok "mock append"
    {|import FS
import Path
handle
  let () = FS.append (Path.of_string "/dev/null") "data" in
  "done"
with
  | fs_append _ k -> k ()
  | return s -> s|}
    "done"

(* ── Suite ───────────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "FS" [
    "real", [
      Alcotest.test_case "mkdir (recursive)"    `Quick test_mkdir;
      Alcotest.test_case "append"               `Quick test_append_real;
      Alcotest.test_case "create_file"          `Quick test_create_file;
      Alcotest.test_case "rename"               `Quick test_rename;
      Alcotest.test_case "copy"                 `Quick test_copy;
      Alcotest.test_case "cwd"                  `Quick test_cwd;
      Alcotest.test_case "exists/is_file/is_dir" `Quick test_exists;
      Alcotest.test_case "size"                 `Quick test_size;
      Alcotest.test_case "list_dir"             `Quick test_list_dir;
      Alcotest.test_case "walk"                 `Quick test_walk;
      Alcotest.test_case "delete"               `Quick test_delete;
    ];
    "mock", [
      Alcotest.test_case "mock append"          `Quick test_mock_append;
    ];
  ]
