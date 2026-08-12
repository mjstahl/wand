open Wand

let contains haystack needle =
  let hn = String.length haystack and nn = String.length needle in
  if nn = 0 then true
  else if nn > hn then false
  else begin
    let found = ref false in
    for i = 0 to hn - nn do
      if String.sub haystack i nn = needle then found := true
    done;
    !found
  end

let with_wand_file content f =
  let path = Filename.temp_file "wand_testrunner_" ".wand" in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect (fun () -> f path) ~finally:(fun () -> Sys.remove path)

let outcomes_of src =
  with_wand_file src (fun path ->
    match Runner.run_test_file path with
    | Ok outcomes -> outcomes
    | Error msg -> Alcotest.failf "expected outcomes, got file-level error: %s" msg)

let file_error_of src =
  with_wand_file src (fun path ->
    match Runner.run_test_file path with
    | Error msg -> msg
    | Ok _ -> Alcotest.fail "expected a file-level error, got outcomes")

let check_pass label = function
  | Runner.TPass l -> Alcotest.(check string) label label l
  | Runner.TFail m -> Alcotest.failf "%s: expected Pass, got Fail: %s" label m
  | Runner.TError m -> Alcotest.failf "%s: expected Pass, got Error: %s" label m

let check_fail_contains label needle = function
  | Runner.TFail m ->
    if not (contains m needle) then
      Alcotest.failf "%s: expected %S in failure message, got: %s" label needle m
  | Runner.TPass l -> Alcotest.failf "%s: expected Fail, got Pass: %s" label l
  | Runner.TError m -> Alcotest.failf "%s: expected Fail, got Error: %s" label m

let check_error_contains label needle = function
  | Runner.TError m ->
    if not (contains m needle) then
      Alcotest.failf "%s: expected %S in error message, got: %s" label needle m
  | Runner.TPass l -> Alcotest.failf "%s: expected Error, got Pass: %s" label l
  | Runner.TFail m -> Alcotest.failf "%s: expected Error, got Fail: %s" label m

(* ── ok / eq ──────────────────────────────────────────────────────────────── *)

let test_pass () =
  match outcomes_of {|let [test] = import Test
test "add" (fn t -> t.eq (2 + 2) 4)|}
  with
  | [o] -> check_pass "add" o
  | os -> Alcotest.failf "expected 1 outcome, got %d" (List.length os)

let test_ok_pass () =
  match outcomes_of {|let [test] = import Test
test "truthy" (fn t -> t.ok (1 == 1))|}
  with
  | [o] -> check_pass "truthy" o
  | os -> Alcotest.failf "expected 1 outcome, got %d" (List.length os)

let test_eq_fail_message () =
  match outcomes_of {|let [test] = import Test
test "mismatch" (fn t -> t.eq 1 2)|}
  with
  | [o] -> check_fail_contains "mismatch" "expected 1, got 2" o
  | os -> Alcotest.failf "expected 1 outcome, got %d" (List.length os)

let test_ok_fail () =
  match outcomes_of {|let [test] = import Test
test "falsy" (fn t -> t.ok (1 == 2))|}
  with
  | [o] -> check_fail_contains "falsy" "assertion failed" o
  | os -> Alcotest.failf "expected 1 outcome, got %d" (List.length os)

(* ── raises ───────────────────────────────────────────────────────────────── *)

let test_raises_pass () =
  match outcomes_of {|let [test] = import Test
import List
test "oob raises" (fn t -> t.raises (fn () -> List.get! 9 [1, 2, 3]))|}
  with
  | [o] -> check_pass "oob raises" o
  | os -> Alcotest.failf "expected 1 outcome, got %d" (List.length os)

let test_raises_fail_when_no_raise () =
  match outcomes_of {|let [test] = import Test
import List
test "valid index" (fn t -> t.raises (fn () -> List.get! 0 [1, 2, 3]))|}
  with
  | [o] -> check_fail_contains "valid index" "expected to raise" o
  | os -> Alcotest.failf "expected 1 outcome, got %d" (List.length os)

(* ── isolation: a raise outside t.raises is caught and doesn't stop the file ── *)

let test_raise_outside_raises_isolated () =
  match outcomes_of {|let [test] = import Test
test "boom" (fn t -> t.eq (1 / 0) 0)
test "after boom" (fn t -> t.eq 1 1)|}
  with
  | [o1; o2] ->
    check_error_contains "boom" "division by zero" o1;
    check_pass "after boom" o2
  | os -> Alcotest.failf "expected 2 outcomes, got %d" (List.length os)

(* ── non-test expressions are ignored, not counted ───────────────────────── *)

let test_non_test_expression_ignored () =
  match outcomes_of {|let [test] = import Test
1 + 2
test "real test" (fn t -> t.eq 1 1)|}
  with
  | [o] -> check_pass "real test" o
  | os -> Alcotest.failf "expected 1 outcome (non-test expr ignored), got %d" (List.length os)

(* ── file-level errors ────────────────────────────────────────────────────── *)

let test_type_error_is_file_level () =
  let msg = file_error_of {|let [test] = import Test
test "bad" (fn t -> t.eq (1 + "oops") 2)|} in
  Alcotest.(check bool) "mentions type error" true (contains msg "type error")

let test_missing_file_is_error () =
  match Runner.run_test_file "/nonexistent/wand_missing_test_file.wand" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected an error for a missing file"

(* ── Suite ────────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Test runner" [
    "ok/eq", [
      Alcotest.test_case "eq pass"          `Quick test_pass;
      Alcotest.test_case "ok pass"          `Quick test_ok_pass;
      Alcotest.test_case "eq fail message"  `Quick test_eq_fail_message;
      Alcotest.test_case "ok fail"          `Quick test_ok_fail;
    ];
    "raises", [
      Alcotest.test_case "raises pass"            `Quick test_raises_pass;
      Alcotest.test_case "raises fail on no-raise" `Quick test_raises_fail_when_no_raise;
    ];
    "isolation", [
      Alcotest.test_case "raise outside raises isolated" `Quick test_raise_outside_raises_isolated;
      Alcotest.test_case "non-test expr ignored"          `Quick test_non_test_expression_ignored;
    ];
    "file-level errors", [
      Alcotest.test_case "type error"    `Quick test_type_error_is_file_level;
      Alcotest.test_case "missing file"  `Quick test_missing_file_is_error;
    ];
  ]
