open Wand

(* A `with` releases however the script ends, including when the script is
   stopped rather than finishing: `exit`, Ctrl-C, or a `kill`. Only a
   process that is destroyed rather than stopped -- SIGKILL -- skips it.

   Signals cannot be tested honestly in-process: what is under test is
   whether an interrupted program unwinds, so the program has to really be
   interrupted. Each case forks, runs a script in the child, signals it, and
   checks from the parent that the directory the script was holding is gone.

   The child writes the directory's name to a file the parent chose, since
   the name is generated at run time and the parent has to know what to
   look for after the child is gone. *)

let script marker =
  Printf.sprintf
    {|import FS
import Path
with FS.temp_dir "wand_sig_" as d ->
  let () = FS.write_file! (Path.of_string "%s") (Path.to_string d) in
  let () = FS.write_file! (Path.of_string "${Path.to_string d}/held.txt") "x" in
  let _ = $(sleep 2) in ()|}
    marker

(* Runs `src` in a forked child, sends `signal` once the marker shows the
   child has acquired, and returns (exit code, directory still present).

   The script waits inside a command, which is where a script usually is
   when someone interrupts it -- and the slower case, since the interpreter
   only regains control when the command returns. *)
let interrupted_run ?(signal = Sys.sigint) ~marker src =
  match Unix.fork () with
  | 0 ->
    (* Child: the exit code is the script's, so the parent can check it. *)
    Runner.install_signal_handlers ();
    let code =
      match Runner.run_string src with
      | _ -> 0
      | exception Evaluator.Interrupted n -> n
      | exception _ -> 1
    in
    Unix._exit code
  | pid ->
    (* Wait for the child to have acquired before signalling, rather than
       guessing with a sleep -- a test that races is worse than no test. *)
    let rec await_acquire tries =
      let held = try In_channel.with_open_text marker In_channel.input_all with _ -> "" in
      if String.trim held <> "" then String.trim held
      else if tries = 0 then ""
      else begin ignore (Unix.select [] [] [] 0.05); await_acquire (tries - 1) end
    in
    let dir = await_acquire 200 in
    Unix.kill pid signal;
    let (_, status) = Unix.waitpid [] pid in
    let code = match status with
      | Unix.WEXITED n -> n
      | Unix.WSIGNALED n -> 128 + n
      | Unix.WSTOPPED n -> 128 + n
    in
    let present = dir <> "" && Sys.file_exists dir in
    if present then ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)));
    (try Sys.remove marker with _ -> ());
    Alcotest.(check bool) "the child acquired before being signalled" true (dir <> "");
    (code, present)

let test_sigint_releases () =
  let marker = Filename.temp_file "wand_sig_m" "" in
  Sys.remove marker;
  let (code, present) = interrupted_run ~signal:Sys.sigint ~marker (script marker) in
  Alcotest.(check bool) "the directory is gone" false present;
  Alcotest.(check int) "exits 130, as a shell reports an interrupt" 130 code

let test_sigterm_releases () =
  let marker = Filename.temp_file "wand_sig_m" "" in
  Sys.remove marker;
  let (code, present) = interrupted_run ~signal:Sys.sigterm ~marker (script marker) in
  Alcotest.(check bool) "the directory is gone" false present;
  Alcotest.(check int) "exits 143" 143 code

(* The interrupt landing inside `acquire`, rather than in the body. The
   release is installed only once acquire returns, so a resource that had
   already become real -- the file written, the lock taken -- had nothing to
   give it back, and an interrupt in that window left it held. The window is
   small, which is what made this a demo that passed everywhere except a
   loaded machine.

   The marker is written after the resource exists and before the work that
   follows it, so the parent signals while acquire is still running. The
   work is pure: a command would end by another route, and this is the one
   that check_interrupt governs. *)
let acquire_script marker =
  Printf.sprintf
    {|import FS
import List
import Path
import Resource
let held = "%s.held"
let r =
  let acquire = fn () ->
    let () = FS.write_file! (Path.of_string held) "x" in
    let () = FS.write_file! (Path.of_string "%s") held in
    let _ = List.length (List.range 0 500000) in
    held
  in
  let release = fn h -> FS.delete! (Path.of_string h) in
  Resource.make acquire release
with r as h -> h|}
    marker marker

let test_interrupt_during_acquire_releases () =
  let marker = Filename.temp_file "wand_sig_m" "" in
  Sys.remove marker;
  let (code, present) = interrupted_run ~signal:Sys.sigint ~marker (acquire_script marker) in
  Alcotest.(check bool) "what acquire had taken is given back" false present;
  Alcotest.(check int) "exits 130" 130 code

(* Nothing survives SIGKILL. Stated as a test so the limit is recorded
   rather than discovered. *)
let test_sigkill_cannot_release () =
  let marker = Filename.temp_file "wand_sig_m" "" in
  Sys.remove marker;
  let (code, present) = interrupted_run ~signal:Sys.sigkill ~marker (script marker) in
  Alcotest.(check bool) "the directory is left behind, as it must be" true present;
  Alcotest.(check int) "killed, not stopped" (128 + Sys.sigkill) code

(* Workers run on their own domains, so each has to see the request for
   itself; and the calling domain must not unwind until they are joined, or
   it would leave workers running and their brackets unreleased. *)
let par_script marker =
  Printf.sprintf
    {|import FS
import Path
import Par
with FS.temp_dir "wand_sig_" as outer ->
  let () = FS.write_file! (Path.of_string "%s") (Path.to_string outer) in
  Par.each 4 (fn n ->
    with FS.temp_dir "wand_sigw_" as d ->
    let () = FS.write_file! (Path.of_string "${Path.to_string outer}/${n}") (Path.to_string d) in
    let _ = $(sleep 2) in ()) [1, 2, 3, 4]|}
    marker

(* Run by starting the real binary rather than by forking this test: the
   script spawns domains, and a forked child of a program that has already
   used them is not sound ground to spawn more from. What is under test is
   the interpreter a user runs, so run that. *)
let wand_binary =
  let dir = Filename.dirname (Filename.dirname Sys.executable_name) in
  Filename.concat (Filename.concat dir "bin") "wand.exe"

let run_script_until_signalled ~marker src =
  let path = Filename.temp_file "wand_sig_script" ".wand" in
  Out_channel.with_open_text path (fun oc -> Out_channel.output_string oc src);
  let devnull = Unix.openfile "/dev/null" [Unix.O_WRONLY] 0o644 in
  let pid = Unix.create_process wand_binary [| wand_binary; path |]
              Unix.stdin devnull devnull in
  let rec await tries =
    let held = try In_channel.with_open_text marker In_channel.input_all with _ -> "" in
    if String.trim held <> "" then String.trim held
    else if tries = 0 then ""
    else begin ignore (Unix.select [] [] [] 0.05); await (tries - 1) end
  in
  let dir = await 200 in
  Unix.kill pid Sys.sigint;
  let (_, status) = Unix.waitpid [] pid in
  Unix.close devnull;
  (try Sys.remove path with _ -> ());
  let code = match status with
    | Unix.WEXITED n -> n
    | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n
  in
  Alcotest.(check bool) "the script acquired before being signalled" true (dir <> "");
  let present = dir <> "" && Sys.file_exists dir in
  if present then ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)));
  (code, present)

let test_par_workers_release () =
  let marker = Filename.temp_file "wand_sig_m" "" in
  Sys.remove marker;
  if not (Sys.file_exists wand_binary) then
    Alcotest.failf "wand binary not found at %s" wand_binary;
  let (code, present) = run_script_until_signalled ~marker (par_script marker) in
  Alcotest.(check bool) "the caller's directory is gone" false present;
  Alcotest.(check int) "exits 130" 130 code;
  (* Each worker recorded its own directory in the caller's, which is gone
     with them -- so what is checked here is that none survived it. *)
  let leftovers =
    Sys.readdir (Filename.get_temp_dir_name ())
    |> Array.to_list
    |> List.filter (fun n ->
         String.length n > 10 && String.sub n 0 10 = "wand_sigw_")
  in
  List.iter (fun n ->
    ignore (Sys.command (Printf.sprintf "rm -rf %s"
      (Filename.quote (Filename.concat (Filename.get_temp_dir_name ()) n))))) leftovers;
  Alcotest.(check int) "no worker left its directory behind" 0 (List.length leftovers)

(* `exit` unwinds like anything else, and keeps its code. *)
let exit_script marker code =
  Printf.sprintf
    {|import FS
import Path
import Proc
with FS.temp_dir "wand_sig_" as d ->
  let () = FS.write_file! (Path.of_string "%s") (Path.to_string d) in
  Proc.exit %d|}
    marker code

let test_exit_releases () =
  List.iter (fun n ->
    let marker = Filename.temp_file "wand_sig_m" "" in
    let src = exit_script marker n in
    let code =
      match Runner.run_string src with
      | _ -> 0
      | exception Evaluator.Interrupted c -> c
    in
    let dir = String.trim (In_channel.with_open_text marker In_channel.input_all) in
    let present = Sys.file_exists dir in
    if present then ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)));
    (try Sys.remove marker with _ -> ());
    Alcotest.(check int) (Printf.sprintf "exit %d keeps its code" n) n code;
    Alcotest.(check bool)
      (Printf.sprintf "exit %d released first" n) false present
  ) [0; 1; 3; 42]

let () =
  Alcotest.run "Signals" [
    "a stopped script still releases", [
      Alcotest.test_case "SIGINT"  `Quick test_sigint_releases;
      Alcotest.test_case "SIGTERM" `Quick test_sigterm_releases;
      Alcotest.test_case "exit n"  `Quick test_exit_releases;
      Alcotest.test_case "Par workers" `Quick test_par_workers_release;
      Alcotest.test_case "during acquire" `Quick test_interrupt_during_acquire_releases;
    ];
    "the limit", [
      Alcotest.test_case "SIGKILL cannot" `Quick test_sigkill_cannot_release;
    ];
  ]
