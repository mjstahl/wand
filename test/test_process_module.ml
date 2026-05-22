open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

let err label input =
  match run input with
  | Error _ -> ()
  | Ok v -> Alcotest.failf "%s: expected error but got: %s" label v

(* ── $() ────────────────────────────────────────────────────────────────── *)

let test_run () =
  ok "captures stdout"    {|$(echo hello)|}    "hello";
  ok "strips newline"     {|$(printf hello)|}  "hello";
  err "raises on failure" {|$(exit 1)|}

(* ── $?() ───────────────────────────────────────────────────────────────── *)

let test_query () =
  ok "stdout field"  {|let r = $?(echo hello); r.stdout|}  "hello";
  ok "code zero"     {|let r = $?(true);        r.code|}   "0";
  ok "code non-zero" {|let r = $?(false);       r.code|}   "1";
  ok "never raises"
    {|let r = $?(exit 42)
r.code == 42|}
    "true"

(* ── stdin via |> ────────────────────────────────────────────────────────── *)

let test_stdin () =
  ok "pipe into cat"
    {|"hello" |> $(cat)|}
    "hello";
  ok "pipe into wc -w"
    {|"hello world" |> $(wc -w | tr -d ' ')|}
    "2";
  ok "pipe into $?()"
    {|let r = "hello" |> $?(cat); r.stdout|}
    "hello"

(* ── interpolation ───────────────────────────────────────────────────────── *)

let test_interp () =
  ok "interpolated command"
    {|let word = "hello"; $(echo ${word})|}
    "hello"

(* ── mock handlers ───────────────────────────────────────────────────────── *)

let test_mock () =
  ok "mock process_run"
    {|handle $(echo hello) with
  | process_run _ k -> k "mocked"|}
    "mocked"

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Process module" [
    "real", [
      Alcotest.test_case "run"   `Quick test_run;
      Alcotest.test_case "query" `Quick test_query;
      Alcotest.test_case "stdin" `Quick test_stdin;
      Alcotest.test_case "interp" `Quick test_interp;
    ];
    "mock", [
      Alcotest.test_case "mock handlers" `Quick test_mock;
    ];
  ]
