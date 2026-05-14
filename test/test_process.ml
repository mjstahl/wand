open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

let err label input =
  match run input with
  | Error _ -> ()
  | Ok s -> Alcotest.failf "%s: expected error but got: %s" label s

let err_contains label input needle =
  match run input with
  | Error msg ->
    let hn = String.length msg and nn = String.length needle in
    let found = ref false in
    for i = 0 to hn - nn do
      if String.sub msg i nn = needle then found := true
    done;
    if not !found then
      Alcotest.failf "%s: expected '%s' in error, got: %s" label needle msg
  | Ok s -> Alcotest.failf "%s: expected error but got: %s" label s

(* ── Basic execution ─────────────────────────────────────────────────────── *)

let test_basic () =
  ok "echo"
    {|$(echo hello)|}
    "hello";
  ok "trailing newline stripped"
    {|$(printf hello)|}
    "hello";
  ok "dynamic cmd via interpolation"
    {|let cmd = "echo world"
$(${cmd})|}
    "world"

let test_composition () =
  ok "result in binding"
    {|let out = $(echo hello)
out|}
    "hello";
  ok "result in expression"
    {|let out = $(echo 3)
out == "3"|}
    "true"

(* ── Error handling ──────────────────────────────────────────────────────── *)

let test_errors () =
  err "nonzero exit"
    {|$(exit 1)|};
  err_contains "shows exit code"
    {|$(sh -c 'exit 42')|}
    "42"

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Process" [
    "execution", [
      Alcotest.test_case "basic"       `Quick test_basic;
      Alcotest.test_case "composition" `Quick test_composition;
    ];
    "errors", [
      Alcotest.test_case "exit errors" `Quick test_errors;
    ];
  ]
