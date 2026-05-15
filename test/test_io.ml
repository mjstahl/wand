open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

let err label input =
  match run input with
  | Error _ -> ()
  | Ok v -> Alcotest.failf "%s: expected error but got: %s" label v

(* ── IO module import ──────────────────────────────────────────────────────── *)

let test_io_import () =
  ok "IO.println_err type checks"
    {|import IO
handle
  let () = IO.println_err "oops" in
  "done"
with
  | io_println_err _ k -> k ()
  | return s -> s|}
    "done"

(* ── Top-level aliases ─────────────────────────────────────────────────────── *)

let test_print_err () =
  ok "print_err type-checks and runs"
    {|handle
        let () = print_err "error message" in
        "ok"
      with
        | io_print_err _ k -> k ()
        | return s -> s|}
    "ok"

let test_println_err () =
  ok "println_err type-checks and runs"
    {|handle
        let () = println_err "error message" in
        "ok"
      with
        | io_println_err _ k -> k ()
        | return s -> s|}
    "ok"

let test_exit_type () =
  (* exit : Int -> 'a — valid in any return position *)
  ok "exit is polymorphic in return type"
    {|let f () : Int = if true then 1 else exit 1
f ()|}
    "1"

(* ── read_line mock ────────────────────────────────────────────────────────── *)

let test_read_line_mock () =
  ok "mock read_line"
    {|handle read_line () with
        | read_line _ k -> k "mocked line"|}
    "mocked line"

(* ── read_all mock ─────────────────────────────────────────────────────────── *)

let test_io_read_all_mock () =
  ok "mock io_read_all"
    {|handle io_read_all () with
        | io_read_all _ k -> k "all of stdin"|}
    "all of stdin"

(* ── flush mock ─────────────────────────────────────────────────────────────── *)

let test_flush_mock () =
  ok "mock io_flush"
    {|handle
        let () = io_flush () in
        "flushed"
      with
        | io_flush _ k -> k ()
        | return s -> s|}
    "flushed"

(* ── Type errors ─────────────────────────────────────────────────────────────── *)

let test_type_errors () =
  err "print_err non-string" {|print_err 42|};
  err "exit non-int"         {|exit "bye"|}

(* ── Suite ───────────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "IO module" [
    "import", [
      Alcotest.test_case "IO import"    `Quick test_io_import;
    ];
    "top-level aliases", [
      Alcotest.test_case "print_err"    `Quick test_print_err;
      Alcotest.test_case "println_err"  `Quick test_println_err;
      Alcotest.test_case "exit type"    `Quick test_exit_type;
    ];
    "mock effects", [
      Alcotest.test_case "read_line"    `Quick test_read_line_mock;
      Alcotest.test_case "read_all"     `Quick test_io_read_all_mock;
      Alcotest.test_case "flush"        `Quick test_flush_mock;
    ];
    "type errors", [
      Alcotest.test_case "type errors"  `Quick test_type_errors;
    ];
  ]
