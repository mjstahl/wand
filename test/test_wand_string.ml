open Wand

(* Migration of test_string_stdlib.ml to a real .wand test file
   (test/wand/string_test.wand) using the Test/wand test framework, run
   here via Runner.run_test_file so `dune test` still gates on it like
   every other suite. See test_wand_list.ml for why the file check must
   happen lazily inside the Alcotest test case. *)

let path = "wand/string_test.wand"

let test_string_wand () =
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
  Alcotest.run "String (wand)" [
    "cases", [ Alcotest.test_case "test/wand/string_test.wand" `Quick test_string_wand ];
  ]
