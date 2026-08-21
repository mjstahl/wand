open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

let contains haystack needle =
  let hn = String.length haystack and nn = String.length needle in
  let rec go i = i + nn <= hn && (String.sub haystack i nn = needle || go (i + 1)) in
  go 0

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


(* ── The tree a glob walks ─────────────────────────────────────────────── *)

(* `FS.glob_in pat dir` answers with what is under `dir`. A symlink is an
   entry like any other -- it can match, and comes back as itself -- but
   walking through one leaves the directory the caller named: a link to
   /etc had a glob over ./data answering with files ./data does not
   contain, and a link back to an ancestor sent the walk round in a circle
   until the path outgrew what the system would take. *)

let rec rm_rf path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun e -> rm_rf (Filename.concat path e)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Sys.remove path
  | exception Unix.Unix_error _ -> ()

let with_tree f =
  let root = Filename.temp_file "wand_glob_" "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  Fun.protect ~finally:(fun () -> rm_rf root) (fun () -> f root)

let write path text =
  Out_channel.with_open_text path (fun oc -> Out_channel.output_string oc text)

let glob_in pat dir =
  let src = Printf.sprintf
    {|import FS
import List
import Path
List.map Path.to_string (FS.glob_in %s (Path.of_string "%s"))|} pat dir
  in
  match run src with
  | Ok v -> v
  | Error m -> Alcotest.failf "glob failed: %s" m

let test_a_glob_stays_under_its_directory () =
  with_tree (fun root ->
    let base = Filename.concat root "data" in
    let outside = Filename.concat root "secret" in
    Unix.mkdir base 0o755;
    Unix.mkdir outside 0o755;
    write (Filename.concat base "a.conf") "x";
    write (Filename.concat outside "hidden.conf") "x";
    Unix.symlink outside (Filename.concat base "link");
    let out = glob_in "**.conf" base in
    if contains out "hidden.conf" then
      Alcotest.failf "the glob followed a link out of its directory: %s" out;
    if not (contains out "a.conf") then
      Alcotest.failf "the glob missed a real file: %s" out)

let test_a_glob_answers_with_a_matching_link () =
  with_tree (fun root ->
    let base = Filename.concat root "data" in
    Unix.mkdir base 0o755;
    write (Filename.concat root "target.conf") "x";
    Unix.symlink (Filename.concat root "target.conf")
      (Filename.concat base "via-link.conf");
    let out = glob_in "**.conf" base in
    if not (contains out "via-link.conf") then
      Alcotest.failf "a link that matches is still an answer: %s" out)

(* A link to an ancestor: the walk must end, and end with the real files. *)
let test_a_glob_does_not_circle () =
  with_tree (fun root ->
    let base = Filename.concat root "data" in
    Unix.mkdir base 0o755;
    write (Filename.concat base "a.conf") "x";
    Unix.symlink root (Filename.concat base "up");
    let out = glob_in "**.conf" base in
    if contains out "up/" then
      Alcotest.failf "the walk went through the link: %s" out)

(* ── The permissions a file is created with ────────────────────────────── *)

(* `FS.write_file` took the channel default of 0666 while `FS.create_file`
   and `FS.append` asked for 0644, so which of the three a script called
   decided whether the file it wrote could be written by anyone else --
   visible whenever the umask does not hide it. `FS.copy` had the same
   default, which cost a copied script its executable bit and made a copy
   of a 0600 file readable by everyone. *)

let mode_of path = (Unix.stat path).Unix.st_perm

(* Under a permissive umask, since a umask can only take bits away: what is
   being tested is the mode the code asks for. *)
let with_open_umask f =
  let old = Unix.umask 0o000 in
  Fun.protect ~finally:(fun () -> ignore (Unix.umask old)) f

let wand_ok src =
  match run src with
  | Ok _ -> ()
  | Error m -> Alcotest.failf "script failed: %s" m

let test_written_files_are_not_world_writable () =
  with_tree (fun root ->
    with_open_umask (fun () ->
      let path = Filename.concat root "written" in
      wand_ok (Printf.sprintf
        {|import FS
import Path
FS.write_file! (Path.of_string "%s") "x"|} path);
      Alcotest.(check int) "write_file asks for 0644" 0o644 (mode_of path)))

let test_a_copy_carries_the_source_mode () =
  with_tree (fun root ->
    with_open_umask (fun () ->
      let script = Filename.concat root "script.sh" in
      let secret = Filename.concat root "secret" in
      write script "#!/bin/sh\n";
      write secret "s";
      Unix.chmod script 0o755;
      Unix.chmod secret 0o600;
      let copy_to src dst =
        wand_ok (Printf.sprintf
          {|import FS
import Path
FS.copy! (Path.of_string "%s") (Path.of_string "%s")|} src dst)
      in
      let script_copy = Filename.concat root "script-copy.sh" in
      let secret_copy = Filename.concat root "secret-copy" in
      copy_to script script_copy;
      copy_to secret secret_copy;
      Alcotest.(check int) "a copied script is still executable" 0o755
        (mode_of script_copy);
      Alcotest.(check int) "a copied private file is still private" 0o600
        (mode_of secret_copy);
      (* Overwriting is not the place to widen a mode somebody chose. *)
      let existing = Filename.concat root "existing" in
      write existing "old";
      Unix.chmod existing 0o600;
      copy_to script existing;
      Alcotest.(check int) "an existing destination keeps its own mode" 0o600
        (mode_of existing)))


(* ── What a rehearsal hands back ───────────────────────────────────────── *)

(* `--dry-run` does not create a temp directory; it reports the request and
   answers with a name. That name used to be `/tmp/wand-dry-run-dir` every
   time, in a directory every user on the machine can write, so anyone
   could hold the path first -- or put a symlink there -- and a script
   reading back what it believed it had just been given would read what was
   left for it. The name is unpredictable now, and the line reporting it
   still names the one the script was handed.

   Run through the real binary: what is under test is the rehearsal a
   person invokes, report and value together. *)

let wand_binary =
  let dir = Filename.dirname (Filename.dirname Sys.executable_name) in
  Filename.concat (Filename.concat dir "bin") "wand.exe"

let rehearse src =
  let path = Filename.temp_file "wand_dry_run" ".wand" in
  write path src;
  let cmd =
    String.concat " " (List.map Filename.quote [wand_binary; "--dry-run"; path])
    ^ " 2>&1"
  in
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  ignore (Unix.close_process_in ic);
  (try Sys.remove path with Sys_error _ -> ());
  out

let temp_dir_script =
  {|uses {FS.Read, FS.Write, IO}
import FS
import Path
with FS.temp_dir "build-" as d -> println (Path.to_string d)|}

let test_a_rehearsal_names_a_fresh_directory () =
  if not (Sys.file_exists wand_binary) then
    Alcotest.failf "wand binary not found at %s" wand_binary;
  let first  = rehearse temp_dir_script in
  let second = rehearse temp_dir_script in
  List.iter (fun out ->
    if contains out "/tmp/wand-dry-run-dir" then
      Alcotest.failf "the rehearsal still names a fixed path:\n%s" out;
    (* The report says what it substituted, and the script printed what it
       was given: the same name has to appear twice. *)
    match String.split_on_char '\n' (String.trim out) with
    | [reported; printed] ->
      if not (contains reported printed) then
        Alcotest.failf "the report and the value disagree:\n%s" out;
      if Sys.file_exists printed then
        Alcotest.failf "the rehearsal created %s" printed
    | _ -> Alcotest.failf "unexpected rehearsal output:\n%s" out) [first; second];
  if first = second then
    Alcotest.failf "two rehearsals were handed the same name:\n%s" first

(* ── Suite ─────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "FS" [
    "real", [
      Alcotest.test_case "read/write round trip" `Quick test_read_write_round_trip;
    ];
    "what a glob walks", [
      Alcotest.test_case "stays under its directory" `Quick
        test_a_glob_stays_under_its_directory;
      Alcotest.test_case "a matching link is an answer" `Quick
        test_a_glob_answers_with_a_matching_link;
      Alcotest.test_case "a link to an ancestor does not circle" `Quick
        test_a_glob_does_not_circle;
    ];
    "a rehearsal", [
      Alcotest.test_case "names a fresh directory" `Quick
        test_a_rehearsal_names_a_fresh_directory;
    ];
    "how a file is created", [
      Alcotest.test_case "write_file asks for 0644" `Quick
        test_written_files_are_not_world_writable;
      Alcotest.test_case "a copy carries the source mode" `Quick
        test_a_copy_carries_the_source_mode;
    ];
  ]
