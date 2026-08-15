(* The default handler, exercised by running scripts rather than by
   intercepting what they perform.

   `test/wand/test_io.wand` covers these functions with `handle ... with |
   IO!println_err _ k -> k ()`, which is the right way to test a script's
   behaviour and the reason a gap here went unnoticed: a test that installs
   its own handler passes whether or not the default one has a case. It did
   not, and `IO.print_err`, `IO.println_err` and `IO.read_line` each killed
   the interpreter with an unhandled OCaml effect.

   So these run the binary, feed it stdin, and read what came back out. *)

let wand_binary =
  let dir = Filename.dirname (Filename.dirname Sys.executable_name) in
  Filename.concat (Filename.concat dir "bin") "wand.exe"

let scratch () =
  let d = Filename.temp_file "wand_io_" "" in
  Sys.remove d;
  Unix.mkdir d 0o755;
  d

(* stdout and stderr are captured separately: the whole point of these
   functions is which stream they land on. *)
let run ?(stdin_text = "") source =
  let dir = scratch () in
  let script = Filename.concat dir "s.wand" in
  Out_channel.with_open_text script (fun oc ->
    Out_channel.output_string oc source);
  let out_file = Filename.concat dir "out" in
  let err_file = Filename.concat dir "err" in
  let in_file = Filename.concat dir "in" in
  Out_channel.with_open_text in_file (fun oc ->
    Out_channel.output_string oc stdin_text);
  let cmd =
    Printf.sprintf "%s %s < %s > %s 2> %s" (Filename.quote wand_binary)
      (Filename.quote script) (Filename.quote in_file)
      (Filename.quote out_file) (Filename.quote err_file)
  in
  let code = Sys.command cmd in
  let read p = In_channel.with_open_text p In_channel.input_all in
  (code, read out_file, read err_file)

let check_ok label (code, _, _) =
  Alcotest.(check int) (label ^ ": exit status") 0 code

let test_println_err () =
  let (code, out, err) =
    run "uses {IO}\nimport IO\nIO.println_err \"to stderr\"\n"
  in
  check_ok "println_err" (code, out, err);
  Alcotest.(check string) "lands on stderr" "to stderr\n" err;
  Alcotest.(check string) "and not on stdout" "" out

let test_print_err () =
  let (code, out, err) =
    run "uses {IO}\nimport IO\nIO.print_err \"no newline\"\n"
  in
  check_ok "print_err" (code, out, err);
  Alcotest.(check string) "no newline added" "no newline" err;
  Alcotest.(check string) "and not on stdout" "" out

let test_read_line () =
  let (code, out, err) =
    run ~stdin_text:"first line\nsecond line\n"
      "uses {IO, Raise}\nimport IO\nIO.println (IO.read_line! ())\n"
  in
  check_ok "read_line" (code, out, err);
  Alcotest.(check string) "one line, without its newline" "first line\n" out

(* End of input is not a blank line, and the difference has to survive the
   trip through the handler: returning "" would make a closed stdin look
   like someone pressing return. *)
let test_read_line_at_eof () =
  let (code, out, err) =
    run
      "uses {IO}\nimport IO\nmatch IO.read_line () with\n\
       | Ok l    -> IO.println \"ok: ${l}\"\n\
       | Error e -> IO.println \"error: ${e}\"\n"
  in
  check_ok "read_line at eof" (code, out, err);
  Alcotest.(check string) "an Error, not an empty string" "error: end of input\n"
    out

let () =
  Alcotest.run "io_handler"
    [ ( "stderr",
        [ Alcotest.test_case "println_err" `Quick test_println_err;
          Alcotest.test_case "print_err" `Quick test_print_err
        ] );
      ( "stdin",
        [ Alcotest.test_case "read_line" `Quick test_read_line;
          Alcotest.test_case "read_line at eof" `Quick test_read_line_at_eof
        ] )
    ]
