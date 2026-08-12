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
      Alcotest.test_case "CSV"      `Quick (check_fixture "wand/csv_test.wand");
      Alcotest.test_case "JSON"     `Quick (check_fixture "wand/json_test.wand");
      Alcotest.test_case "TOML"     `Quick (check_fixture "wand/toml_test.wand");
      Alcotest.test_case "Glob"     `Quick (check_fixture "wand/glob_test.wand");
      Alcotest.test_case "Imports"  `Quick (check_fixture "wand/imports_test.wand");
    ];
    "language", [
      Alcotest.test_case "Eval"          `Quick (check_fixture "wand/eval_test.wand");
      Alcotest.test_case "Script"        `Quick (check_fixture "wand/script_test.wand");
      Alcotest.test_case "Typedef"       `Quick (check_fixture "wand/typedef_test.wand");
      Alcotest.test_case "Generics"      `Quick (check_fixture "wand/generics_test.wand");
      Alcotest.test_case "Contracts"     `Quick (check_fixture "wand/contracts_test.wand");
      Alcotest.test_case "Process"       `Quick (check_fixture "wand/process_test.wand");
      Alcotest.test_case "Strings"       `Quick (check_fixture "wand/strings_test.wand");
      Alcotest.test_case "Effects"       `Quick (check_fixture "wand/effects_test.wand");
      Alcotest.test_case "List patterns" `Quick (check_fixture "wand/list_patterns_test.wand");
      Alcotest.test_case "IO"            `Quick (check_fixture "wand/io_test.wand");
      Alcotest.test_case "Env"           `Quick (check_fixture "wand/env_test.wand");
    ];
  ]
