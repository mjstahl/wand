open Wand

(* Runs a stdlib module's .wand test fixture (test/wand/<name>.wand) via
   Runner.run_test_file and fails the Alcotest case with details on any
   TFail/TError. Must run lazily inside the Alcotest test case (not at
   module-load time) -- see test_wand_list.ml for why. *)
let check_fixture path () =
  if not (Sys.file_exists path) then
    Alcotest.failf "fixture not found at %s (relative to test sandbox)" path
  else
    match Runner.run_test_file path with
    | Error msg -> Alcotest.failf "file-level error running %s: %s" path msg
    | Ok outcomes ->
      let failures = List.filter_map (function
        | Runner.TPass _ -> None
        | Runner.TFail msg | Runner.TError msg -> Some msg
      ) outcomes in
      if failures <> [] then
        Alcotest.failf "%d/%d wand tests failed:\n%s"
          (List.length failures) (List.length outcomes) (String.concat "\n" failures)

let () =
  Alcotest.run "Stdlib (wand)" [
    "modules", [
      Alcotest.test_case "Path"     `Quick (check_fixture "wand/path_test.wand");
      Alcotest.test_case "Duration" `Quick (check_fixture "wand/duration_test.wand");
      Alcotest.test_case "Regex"    `Quick (check_fixture "wand/regex_test.wand");
      Alcotest.test_case "FS"       `Quick (check_fixture "wand/fs_test.wand");
      Alcotest.test_case "Types"    `Quick (check_fixture "wand/types_test.wand");
    ];
  ]
