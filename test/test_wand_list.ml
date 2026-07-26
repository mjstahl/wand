open Wand

(* Proof-of-concept migration of test_list_stdlib.ml to a real .wand test
   file (test/wand/list_test.wand) using the Test/wand test framework,
   run here via Runner.run_test_file so `dune test` still gates on it
   like every other suite. The file check must happen lazily inside the
   Alcotest test case (not at module-load time) -- Alcotest's working
   directory at that point is what makes the relative path below
   resolve, matching the pattern already proven in
   test_formatter.ml's test_idempotent_stdlib. *)

let path = "wand/list_test.wand"

let test_list_wand () =
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
  Alcotest.run "List (wand)" [
    "cases", [ Alcotest.test_case "test/wand/list_test.wand" `Quick test_list_wand ];
  ]
