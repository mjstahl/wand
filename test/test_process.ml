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
    {|start $("echo hello")|}
    "hello";
  ok "trailing newline stripped"
    {|start $("printf hello")|}
    "hello";
  ok "dynamic cmd"
    {|let cmd = "echo world"
start $(cmd)|}
    "world"

let test_composition () =
  ok "result in binding"
    {|let out = $("echo hello")
start out|}
    "hello";
  ok "result in expression"
    {|let out = $("echo 3")
start out == "3"|}
    "true"

(* ── Error handling ──────────────────────────────────────────────────────── *)

let test_errors () =
  err "nonzero exit"
    {|start $("exit 1")|};
  err_contains "shows exit code"
    {|start $("sh -c 'exit 42'")|}
    "42"

(* ── Type errors ─────────────────────────────────────────────────────────── *)

let test_type_errors () =
  err "non-string cmd" {|start $(42)|};
  err "non-string var" {|let n = 1
start $(n)|}

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Process" [
    "execution", [
      Alcotest.test_case "basic"       `Quick test_basic;
      Alcotest.test_case "composition" `Quick test_composition;
    ];
    "errors", [
      Alcotest.test_case "exit errors" `Quick test_errors;
      Alcotest.test_case "type errors" `Quick test_type_errors;
    ];
  ]
