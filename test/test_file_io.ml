open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

let err label input =
  match run input with
  | Error _ -> ()
  | Ok v -> Alcotest.failf "%s: expected error but got: %s" label v

(* ── Mock handlers ─────────────────────────────────────────────────────────── *)

let test_mock_read () =
  ok "mock read_file"
    {|start handle read_file "/nonexistent" with
        | read_file _ k -> k "mocked content"|}
    "mocked content"

let test_mock_write () =
  ok "mock write_file"
    {|start handle
        let () = write_file "/nonexistent" "data" in
        "done"
      with
        | write_file _ k -> k ()
        | return s -> s|}
    "done"

let test_mock_capture_path () =
  ok "capture write path"
    {|start handle
        let () = write_file "/tmp/foo.txt" "hello" in
        "wrote"
      with
        | write_file (path, _) k -> path ++ ": ok" ++ k ()
        | return s -> s|}
    "/tmp/foo.txt: okwrote"

(* ── Real I/O ──────────────────────────────────────────────────────────────── *)

let test_real_read () =
  let tmp = Filename.temp_file "wand_test_" ".txt" in
  Out_channel.with_open_text tmp (fun oc ->
    Out_channel.output_string oc "hello from file");
  let src = Printf.sprintf {|start read_file "%s"|} tmp in
  (try ok "read real file" src "hello from file"
   with e -> (try Sys.remove tmp with _ -> ()); raise e);
  (try Sys.remove tmp with _ -> ())

let test_real_write () =
  let tmp = Filename.temp_file "wand_test_" ".txt" in
  (try Sys.remove tmp with _ -> ());
  let src = Printf.sprintf {|start let () = write_file "%s" "written" in "ok"|} tmp in
  ok "write real file" src "ok";
  let content = In_channel.with_open_text tmp In_channel.input_all in
  Alcotest.(check string) "file content" "written" content;
  (try Sys.remove tmp with _ -> ())

let test_real_roundtrip () =
  let tmp = Filename.temp_file "wand_test_" ".txt" in
  let src = Printf.sprintf
    {|start
      let () = write_file "%s" "round trip" in
      read_file "%s"|} tmp tmp in
  (try ok "roundtrip" src "round trip"
   with e -> (try Sys.remove tmp with _ -> ()); raise e);
  (try Sys.remove tmp with _ -> ())

(* ── Runtime errors ─────────────────────────────────────────────────────────── *)

let test_runtime_errors () =
  err "read nonexistent" {|start read_file "/no/such/path/wand_test_xyz"|}

(* ── Type errors ─────────────────────────────────────────────────────────── *)

let test_type_errors () =
  err "read_file non-string"      {|start read_file 42|};
  err "write_file non-string arg" {|start write_file 42 "content"|}

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "File IO" [
    "mock", [
      Alcotest.test_case "mock read"         `Quick test_mock_read;
      Alcotest.test_case "mock write"        `Quick test_mock_write;
      Alcotest.test_case "capture write arg" `Quick test_mock_capture_path;
    ];
    "real", [
      Alcotest.test_case "read file"   `Quick test_real_read;
      Alcotest.test_case "write file"  `Quick test_real_write;
      Alcotest.test_case "round trip"  `Quick test_real_roundtrip;
    ];
    "errors", [
      Alcotest.test_case "runtime errors" `Quick test_runtime_errors;
      Alcotest.test_case "type errors"    `Quick test_type_errors;
    ];
  ]
