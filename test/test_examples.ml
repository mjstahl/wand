open Wand

(* The examples are the first thing a visitor runs, so a broken one costs more
   than a broken test. Four of eight were broken at once -- a removed module, a
   stale import form, a stale $() form, and a Result used as an Int -- and
   nothing noticed, because nothing ran them.

   Every example is typechecked, which is what would have caught three of those
   four. Examples that only compute are also executed; the ones that shell out
   to git/whoami/uname are not, since the sandbox is not a git repository and a
   test that depends on the host's tools fails for reasons that have nothing to
   do with the example. *)

let dir = "../examples"

(* Examples whose behavior does not depend on the host: no $(), no stdin. *)
let hermetic =
  [ "hello.wand"; "fibonacci.wand"; "greetings.wand"; "shapes.wand";
    "decode-renamed-keys.wand"; "decode-nested-fields.wand";
    "decode-tagged-union.wand" ]

(* Walked rather than listed: the ports live in `examples/ports/`, and a
   sweep that stopped at the top level would typecheck none of them. Names
   are relative to `examples/`, so a failure says which file. *)
let example_files () =
  if not (Sys.file_exists dir) then
    Alcotest.failf "examples not found at %s (relative to test sandbox)" dir;
  let rec walk prefix =
    Sys.readdir (Filename.concat dir prefix)
    |> Array.to_list
    |> List.concat_map (fun entry ->
      let rel = if prefix = "" then entry else Filename.concat prefix entry in
      if Sys.is_directory (Filename.concat dir rel) then walk rel
      else if Filename.check_suffix entry ".wand" then [rel]
      else [])
  in
  List.sort String.compare (walk "")

(* The tool's own entry point, rather than a second assembly of the same
   stages. This test built its own and the copy fell behind: it did not pass
   the type names an import carries, so a constructor from an imported
   module -- `FS.Held` -- read as a module that declares no types, and an
   example `wand t` accepts failed here. What a visitor runs is
   `wand t <file>`, and that is `typecheck_file`. *)
let typecheck path =
  match Runner.typecheck_file path with
  | Ok _ -> Ok ()
  | Error d -> Error (Diag.legacy d)

let test_all_typecheck () =
  List.iter (fun name ->
    match typecheck (Filename.concat dir name) with
    | Ok () -> ()
    | Error msg -> Alcotest.failf "examples/%s does not typecheck: %s" name msg
  ) (example_files ())

let test_hermetic_run () =
  List.iter (fun name ->
    match Runner.run_file (Filename.concat dir name) with
    | Ok _ -> ()
    | Error msg -> Alcotest.failf "examples/%s failed to run: %s" name msg
  ) hermetic

(* If an example is added, it is covered by the typecheck sweep automatically;
   this keeps the hermetic list from naming a file that no longer exists. *)
let test_hermetic_list_is_current () =
  let all = example_files () in
  List.iter (fun name ->
    if not (List.mem name all) then
      Alcotest.failf "hermetic list names %s, which is not in examples/" name
  ) hermetic

let () =
  Alcotest.run "Examples" [
    "all", [
      Alcotest.test_case "typecheck"      `Quick test_all_typecheck;
      Alcotest.test_case "hermetic list"  `Quick test_hermetic_list_is_current;
    ];
    "hermetic", [
      Alcotest.test_case "run" `Quick test_hermetic_run;
    ];
  ]
