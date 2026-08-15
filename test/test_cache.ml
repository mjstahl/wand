open Wand

(* The compile cache keeps a module's inferred types between runs. What has
   to hold is not that it is fast but that it cannot be wrong: an entry is
   only reachable while every file it was inferred against is unchanged.

   Each case runs the wand binary twice in a scratch directory with its own
   cache, because the thing under test is what survives between processes. *)

let wand_binary =
  let dir = Filename.dirname (Filename.dirname Sys.executable_name) in
  Filename.concat (Filename.concat dir "bin") "wand.exe"

let write path contents =
  Out_channel.with_open_text path (fun oc -> Out_channel.output_string oc contents)

let run ~dir ~cache args =
  let cmd =
    Printf.sprintf "cd %s && XDG_CACHE_HOME=%s %s %s 2>&1"
      (Filename.quote dir) (Filename.quote cache) (Filename.quote wand_binary)
      (String.concat " " (List.map Filename.quote args))
  in
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  ignore (Unix.close_process_in ic);
  String.trim out

let scratch () =
  let d = Filename.temp_file "wand_cache_" "" in
  Sys.remove d; Unix.mkdir d 0o755;
  let c = d ^ "_cache" in Unix.mkdir c 0o755;
  (d, c)

let test_repeated_runs_agree () =
  let (d, c) = scratch () in
  write (Filename.concat d "mod.wand") "let greet name = \"hello, ${name}\"";
  write (Filename.concat d "main.wand") "let m = import ./mod\nm.greet \"world\"";
  let first  = run ~dir:d ~cache:c ["main.wand"] in
  let second = run ~dir:d ~cache:c ["main.wand"] in
  Alcotest.(check string) "a cold run" "hello, world" first;
  Alcotest.(check string) "and a cached one" "hello, world" second

(* The entry was inferred against the dependency, so changing the dependency
   has to make it unreachable -- this is the whole design. *)
let test_editing_a_dependency_is_seen () =
  let (d, c) = scratch () in
  write (Filename.concat d "mod.wand") "let greet name = \"hello, ${name}\"";
  write (Filename.concat d "main.wand") "let m = import ./mod\nm.greet \"world\"";
  ignore (run ~dir:d ~cache:c ["main.wand"]);
  write (Filename.concat d "mod.wand") "let greet name = \"goodbye, ${name}\"";
  Alcotest.(check string) "the new answer, not the cached one"
    "goodbye, world" (run ~dir:d ~cache:c ["main.wand"])

(* The sharper version: the dependency's *type* changes, so what was cached
   is not merely out of date but wrong. The error still has to appear. *)
let test_a_dependency_type_change_still_errors () =
  let (d, c) = scratch () in
  write (Filename.concat d "mod.wand") "let greet name = \"hello, ${name}\"";
  write (Filename.concat d "main.wand") "let m = import ./mod\nm.greet \"world\"";
  ignore (run ~dir:d ~cache:c ["main.wand"]);
  write (Filename.concat d "mod.wand") "let greet n = n + 1";
  let out = run ~dir:d ~cache:c ["main.wand"] in
  let has_error =
    String.length out >= 5 && String.sub out 0 5 = "Error"
  in
  Alcotest.(check bool) ("a type error, got: " ^ out) true has_error

(* An entry that cannot be read is a miss, not a failure. *)
let test_a_corrupt_entry_is_survivable () =
  let (d, c) = scratch () in
  write (Filename.concat d "mod.wand") "let n = 41";
  write (Filename.concat d "main.wand") "let m = import ./mod\nm.n + 1";
  Alcotest.(check string) "first run" "42" (run ~dir:d ~cache:c ["main.wand"]);
  let entries = Sys.readdir (Filename.concat c "wand") in
  Array.iter (fun e ->
    write (Filename.concat (Filename.concat c "wand") e) "not a marshalled value")
    entries;
  Alcotest.(check string) "still runs" "42" (run ~dir:d ~cache:c ["main.wand"])

(* `WAND_CACHE` is read for what it says, not for being set at all: the
   values a reader picks to mean off have to mean off, and everything else --
   including the empty string a shell leaves behind for an unset variable --
   has to leave the cache alone. *)
let run_with_cache_var value dir cache =
  let cmd =
    Printf.sprintf "cd %s && WAND_CACHE=%s XDG_CACHE_HOME=%s %s main.wand 2>&1"
      (Filename.quote dir) (Filename.quote value) (Filename.quote cache)
      (Filename.quote wand_binary)
  in
  let ic = Unix.open_process_in cmd in
  let out = String.trim (In_channel.input_all ic) in
  ignore (Unix.close_process_in ic);
  let wand_dir = Filename.concat cache "wand" in
  let entries = if Sys.file_exists wand_dir then Array.length (Sys.readdir wand_dir) else 0 in
  (out, entries)

let test_cache_can_be_turned_off () =
  List.iter (fun value ->
    let (d, c) = scratch () in
    write (Filename.concat d "mod.wand") "let n = 41";
    write (Filename.concat d "main.wand") "let m = import ./mod\nm.n + 1";
    let (out, entries) = run_with_cache_var value d c in
    Alcotest.(check string) ("runs with WAND_CACHE=" ^ value) "42" out;
    Alcotest.(check int) ("wrote nothing with WAND_CACHE=" ^ value) 0 entries
  ) ["0"; "false"; "no"; "off"; "OFF"]

let test_other_values_leave_it_on () =
  List.iter (fun value ->
    let (d, c) = scratch () in
    write (Filename.concat d "mod.wand") "let n = 41";
    write (Filename.concat d "main.wand") "let m = import ./mod\nm.n + 1";
    let (out, entries) = run_with_cache_var value d c in
    Alcotest.(check string) ("runs with WAND_CACHE=" ^ value) "42" out;
    if entries = 0 then
      Alcotest.failf "WAND_CACHE=%S should have left the cache on" value
  ) ["1"; "true"; "yes"; ""]

let () =
  Alcotest.run "Compile cache" [
    "between runs", [
      Alcotest.test_case "repeated runs agree"     `Quick test_repeated_runs_agree;
      Alcotest.test_case "editing a dependency"    `Quick test_editing_a_dependency_is_seen;
      Alcotest.test_case "a dependency's type"     `Quick test_a_dependency_type_change_still_errors;
    ];
    "when it cannot be trusted", [
      Alcotest.test_case "a corrupt entry"         `Quick test_a_corrupt_entry_is_survivable;
      Alcotest.test_case "turned off"              `Quick test_cache_can_be_turned_off;
      Alcotest.test_case "left on"                 `Quick test_other_values_leave_it_on;
    ];
  ]
