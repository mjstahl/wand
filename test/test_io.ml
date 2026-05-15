open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

let err label input =
  match run input with
  | Error _ -> ()
  | Ok v -> Alcotest.failf "%s: expected error but got: %s" label v

(* ── IO module ─────────────────────────────────────────────────────────────── *)

let test_print_err () =
  ok "IO.print_err"
    {|import IO
handle
  let () = IO.print_err "error message" in
  "ok"
with
  | io_print_err _ k -> k ()
  | return s -> s|}
    "ok"

let test_println_err () =
  ok "IO.println_err"
    {|import IO
handle
  let () = IO.println_err "error message" in
  "ok"
with
  | io_println_err _ k -> k ()
  | return s -> s|}
    "ok"

let test_read_line () =
  ok "IO.read_line mock"
    {|import IO
handle IO.read_line () with
  | io_read_line _ k -> k "mocked line"|}
    "mocked line"

let test_read_all () =
  ok "IO.read_all mock"
    {|import IO
handle IO.read_all () with
  | io_read_all _ k -> k "all of stdin"|}
    "all of stdin"

let test_flush () =
  ok "IO.flush mock"
    {|import IO
handle
  let () = IO.flush () in
  "flushed"
with
  | io_flush _ k -> k ()
  | return s -> s|}
    "flushed"

(* ── exit (global) ─────────────────────────────────────────────────────────── *)

let test_exit_type () =
  ok "exit is polymorphic in return type"
    {|let f () : Int = if true then 1 else exit 1
f ()|}
    "1"

(* ── Type errors ─────────────────────────────────────────────────────────────── *)

let test_type_errors () =
  err "IO.print_err non-string" {|import IO
IO.print_err 42|};
  err "exit non-int" {|exit "bye"|}

(* ── Suite ───────────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "IO module" [
    "IO module", [
      Alcotest.test_case "print_err"   `Quick test_print_err;
      Alcotest.test_case "println_err" `Quick test_println_err;
      Alcotest.test_case "read_line"   `Quick test_read_line;
      Alcotest.test_case "read_all"    `Quick test_read_all;
      Alcotest.test_case "flush"       `Quick test_flush;
    ];
    "globals", [
      Alcotest.test_case "exit type"   `Quick test_exit_type;
    ];
    "type errors", [
      Alcotest.test_case "type errors" `Quick test_type_errors;
    ];
  ]
