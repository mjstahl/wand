open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

let err label input =
  match run input with
  | Error _ -> ()
  | Ok v -> Alcotest.failf "%s: expected error but got: %s" label v

(* ── run ─────────────────────────────────────────────────────────────────── *)

let test_run () =
  ok "captures stdout"
    {|import Process
Process.run "echo hello"|}
    "hello";
  ok "strips trailing newline"
    {|import Process
Process.run "printf hello"|}
    "hello";
  err "raises on non-zero exit"
    {|import Process
Process.run "exit 1"|}

(* ── run_quiet ───────────────────────────────────────────────────────────── *)

let test_run_quiet () =
  ok "returns unit"
    {|import Process
let () = Process.run_quiet "echo hello"
"done"|}
    "done";
  err "raises on non-zero exit"
    {|import Process
Process.run_quiet "exit 1"|}

(* ── exit_code ───────────────────────────────────────────────────────────── *)

let test_exit_code () =
  ok "zero on success"
    {|import Process
Process.exit_code "true"|}
    "0";
  ok "non-zero on failure"
    {|import Process
Process.exit_code "false"|}
    "1";
  ok "specific exit code"
    {|import Process
Process.exit_code "sh -c 'exit 42'"|}
    "42";
  ok "does not raise on failure"
    {|import Process
let code = Process.exit_code "false"
code == 1|}
    "true"

(* ── pid ─────────────────────────────────────────────────────────────────── *)

let test_pid () =
  ok "returns an int > 0"
    {|import Process
Process.pid () > 0|}
    "true"

(* ── mock handlers ───────────────────────────────────────────────────────── *)

let test_mock () =
  ok "mock run"
    {|import Process
handle Process.run "ls" with
  | process_run _ k -> k "mocked"|}
    "mocked";
  ok "mock exit_code"
    {|import Process
handle Process.exit_code "false" with
  | process_exit_code _ k -> k 99|}
    "99"

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Process module" [
    "real", [
      Alcotest.test_case "run"        `Quick test_run;
      Alcotest.test_case "run_quiet"  `Quick test_run_quiet;
      Alcotest.test_case "exit_code"  `Quick test_exit_code;
      Alcotest.test_case "pid"        `Quick test_pid;
    ];
    "mock", [
      Alcotest.test_case "mock handlers" `Quick test_mock;
    ];
  ]
