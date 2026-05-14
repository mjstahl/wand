open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

let err label input =
  match run input with
  | Error _ -> ()
  | Ok v -> Alcotest.failf "%s: expected error but got: %s" label v

(* ── Default handler ─────────────────────────────────────────────────────── *)

(* print/println go to stdout via default handler; returns its value *)
let test_default_io () =
  ok "print returns unit"   {|let () = print "hi" in 42|}  "42";
  ok "println returns unit" {|let () = println "hi" in 99|} "99"

(* ── Sequencing ──────────────────────────────────────────────────────────── *)

let test_semicolon () =
  ok "newline sequences"
    {|handle
        let () = print "a" in
        let () = print "b" in
        print "c"
      with
        | print s k -> s ++ k ()
        | return _  -> ""|}
    "abc";
  ok "unit sequencing"
    {|let () = print "x" in 42|}
    "42"

(* ── Custom handlers ─────────────────────────────────────────────────────── *)

let test_capture () =
  ok "collect prints"
    {|handle
        let () = print "hello" in
        print " world"
      with
        | print s k -> s ++ k ()
        | return _  -> ""|}
    "hello world";
  ok "count prints"
    {|handle
        let () = print "a" in
        let () = print "b" in
        print "c"
      with
        | print _ k -> 1 + k ()
        | return _  -> 0|}
    "3"

let test_return_arm () =
  ok "transform return value"
    {|handle 42 with | return n -> n * 2|}
    "84";
  ok "no effect arms needed"
    {|handle 10 + 5 with | return n -> n|}
    "15"

let test_propagates () =
  (* No print arm — effect propagates to outer default handler *)
  ok "unhandled effect reaches default"
    {|handle
        let () = print "x" in 1
      with
        | return n -> n|}
    "1"

(* ── Pattern matching on effect args ─────────────────────────────────────── *)

let test_effect_patterns () =
  ok "literal match on arg"
    {|handle
        let () = print "hello" in
        print "world"
      with
        | print "hello" k -> "H" ++ k ()
        | print s       k -> s ++ k ()
        | return _        -> ""|}
    "Hworld"

(* ── Process effect ──────────────────────────────────────────────────────── *)

let test_process_mock () =
  ok "mock process"
    {|handle
        $("echo real")
      with
        | process_run _ k -> k "mocked"|}
    "mocked"

(* ── Type errors ─────────────────────────────────────────────────────────── *)

let test_type_errors () =
  err "unbound var" {|println undefined_var|}

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Effects" [
    "IO", [
      Alcotest.test_case "default handler"  `Quick test_default_io;
      Alcotest.test_case "semicolon"        `Quick test_semicolon;
      Alcotest.test_case "capture"          `Quick test_capture;
      Alcotest.test_case "return arm"       `Quick test_return_arm;
      Alcotest.test_case "propagates"       `Quick test_propagates;
      Alcotest.test_case "arg patterns"     `Quick test_effect_patterns;
    ];
    "process", [
      Alcotest.test_case "mock process"     `Quick test_process_mock;
    ];
    "types", [
      Alcotest.test_case "type errors"      `Quick test_type_errors;
    ];
  ]
