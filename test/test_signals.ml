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
  let () = FS.write_file! "%s" (Path.to_string d) in
  let () = FS.write_file! "${Path.to_string d}/held.txt" "x" in
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

(* Nothing survives SIGKILL. Stated as a test so the limit is recorded
   rather than discovered. *)
let test_sigkill_cannot_release () =
  let marker = Filename.temp_file "wand_sig_m" "" in
  Sys.remove marker;
  let (code, present) = interrupted_run ~signal:Sys.sigkill ~marker (script marker) in
  Alcotest.(check bool) "the directory is left behind, as it must be" true present;
  Alcotest.(check int) "killed, not stopped" (128 + Sys.sigkill) code

(* `exit` unwinds like anything else, and keeps its code. *)
let exit_script marker code =
  Printf.sprintf
    {|import FS
import Path
with FS.temp_dir "wand_sig_" as d ->
  let () = FS.write_file! "%s" (Path.to_string d) in
  exit %d|}
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
    ];
    "the limit", [
      Alcotest.test_case "SIGKILL cannot" `Quick test_sigkill_cannot_release;
    ];
  ]
