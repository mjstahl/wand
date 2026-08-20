(* What a script is handed on its command line.

   `--dry-run` and `--trace` are wand's wherever they appear -- before the
   path or after it -- and a script never receives either. That costs a
   script the use of those two names, which was weighed and accepted: the
   alternative is that `wand deploy.wand --dry-run` runs the deploy for
   real. Someone reaching for a rehearsal and getting a deployment is a
   worse failure than a script that has to call its own flag something else,
   and the position of a flag is not a thing anyone should have to be right
   about under those stakes.

   So this pins the shadowing rather than guarding against it. Anything else
   wand knows -- `--json`, `--file`, `--load`, `--strict`, `--fix` -- belongs
   to a subcommand, and no subcommand runs a script with arguments, so those
   reach a script untouched and are pinned here too.

   These run the real binary, because the question is what the CLI does with
   argv before any of the library sees it. *)

let wand_binary =
  let dir = Filename.dirname (Filename.dirname Sys.executable_name) in
  Filename.concat (Filename.concat dir "bin") "wand.exe"

(* A script that reports its own arguments and nothing else. *)
let argv_script = "wand_argv_probe.wand"

let write_probe () =
  let oc = open_out argv_script in
  output_string oc
    "uses {Env, IO}\n\nimport Env\nimport IO\n\nIO.println \"%{Env.args ()}\"\n";
  close_out oc

let run args =
  let cmd =
    String.concat " " (List.map Filename.quote (wand_binary :: args)) ^ " 2>&1"
  in
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  ignore (Unix.close_process_in ic);
  String.trim out

let check label expected args =
  Alcotest.(check string) label expected (run args)

let test_the_mode_flags_are_wands_wherever_they_appear () =
  write_probe ();
  Fun.protect ~finally:(fun () -> Sys.remove argv_script) (fun () ->
    check "--dry-run is taken, not passed on" "[yes]"
      [argv_script; "--dry-run"; "yes"];
    check "--trace likewise" "[a, b]" [argv_script; "--trace"; "a"; "b"];
    check "and from the middle of an argument list" "[a, b]"
      [argv_script; "a"; "--dry-run"; "b"])

let test_every_other_flag_reaches_the_script () =
  write_probe ();
  Fun.protect ~finally:(fun () -> Sys.remove argv_script) (fun () ->
    check "an ordinary flag" "[--out, /tmp/x]" [argv_script; "--out"; "/tmp/x"];
    (* Flags of the subcommands. None of them is read on this path. *)
    check "--json" "[--json, x]" [argv_script; "--json"; "x"];
    check "--file" "[--file, x]" [argv_script; "--file"; "x"];
    check "--load" "[--load, x]" [argv_script; "--load"; "x"];
    check "--strict and --fix" "[--strict, --fix]"
      [argv_script; "--strict"; "--fix"];
    check "a command name is just a word here" "[s, version]"
      [argv_script; "s"; "version"];
    (* A single dash is not a flag to wand any more than it is to Args. *)
    check "a lone dash and a negative number" "[-, -5]"
      [argv_script; "-"; "-5"])

(* Both positions choose the mode, and both have to keep working: the first
   is what every example writes, the second is what a hand reaches for. *)
let test_both_positions_rehearse () =
  let script = "wand_argv_mode.wand" in
  let out_path = "/tmp/wand_argv_mode_out" in
  let oc = open_out script in
  output_string oc
    ("uses {FS.Write, IO}\n\nimport FS\nimport IO\nimport Path\n\n\
      FS.write_file! (Path.of_string \"" ^ out_path ^ "\") \"x\"\n");
  close_out oc;
  Fun.protect ~finally:(fun () -> Sys.remove script) (fun () ->
    let rehearses label args =
      let out = run args in
      if not (String.length out >= 11 && String.sub out 0 11 = "would write") then
        Alcotest.failf "%s did not rehearse: %s" label out;
      if Sys.file_exists out_path then begin
        Sys.remove out_path;
        Alcotest.failf "%s wrote the file" label
      end
    in
    rehearses "--dry-run before the path" ["--dry-run"; script];
    rehearses "--dry-run after the path" [script; "--dry-run"])

let () =
  Alcotest.run "script argv"
    [ ( "arguments",
        [ Alcotest.test_case "mode flags are wand's" `Quick
            test_the_mode_flags_are_wands_wherever_they_appear;
          Alcotest.test_case "every other flag passes through" `Quick
            test_every_other_flag_reaches_the_script;
          Alcotest.test_case "both positions rehearse" `Quick
            test_both_positions_rehearse
        ] )
    ]
