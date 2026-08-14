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
      Alcotest.test_case "Path"     `Quick (check_fixture "wand/test_path.wand");
      Alcotest.test_case "Duration" `Quick (check_fixture "wand/test_duration.wand");
      Alcotest.test_case "Regex"    `Quick (check_fixture "wand/test_regex.wand");
      Alcotest.test_case "FS"       `Quick (check_fixture "wand/test_fs.wand");
      Alcotest.test_case "CSV"      `Quick (check_fixture "wand/test_csv.wand");
      Alcotest.test_case "JSON"     `Quick (check_fixture "wand/test_json.wand");
      Alcotest.test_case "TOML"     `Quick (check_fixture "wand/test_toml.wand");
      Alcotest.test_case "Decode"   `Quick (check_fixture "wand/test_decode.wand");
      Alcotest.test_case "Derive"   `Quick (check_fixture "wand/test_derive.wand");
      Alcotest.test_case "Glob"     `Quick (check_fixture "wand/test_glob.wand");
      Alcotest.test_case "Imports"  `Quick (check_fixture "wand/test_imports.wand");
    ];
    "language", [
      Alcotest.test_case "Eval"          `Quick (check_fixture "wand/test_eval.wand");
      Alcotest.test_case "Script"        `Quick (check_fixture "wand/test_script.wand");
      Alcotest.test_case "Typedef"       `Quick (check_fixture "wand/test_typedef.wand");
      Alcotest.test_case "Generics"      `Quick (check_fixture "wand/test_generics.wand");
      Alcotest.test_case "Contracts"     `Quick (check_fixture "wand/test_contracts.wand");
      Alcotest.test_case "Process"       `Quick (check_fixture "wand/test_process.wand");
      Alcotest.test_case "Strings"       `Quick (check_fixture "wand/test_strings.wand");
      Alcotest.test_case "Effects"       `Quick (check_fixture "wand/test_effects.wand");
      Alcotest.test_case "List patterns" `Quick (check_fixture "wand/test_list_patterns.wand");
      Alcotest.test_case "IO"            `Quick (check_fixture "wand/test_io.wand");
      Alcotest.test_case "Env"           `Quick (check_fixture "wand/test_env.wand");
      Alcotest.test_case "Hermetic"      `Quick (check_fixture "wand/test_hermetic.wand");
      Alcotest.test_case "Par"           `Quick (check_fixture "wand/test_par.wand");
      Alcotest.test_case "Resource"      `Quick (check_fixture "wand/test_resource.wand");
    ];
  ]
