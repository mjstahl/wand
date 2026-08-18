open Wand

(* The server in process: feed request JSON to `handle`, assert on the JSON
   it answers -- no pty, no subprocess, no channels. Stdio is only the
   production instantiation of the same loop, and its framing is covered
   separately at the bottom. *)

let notif method_ params : Yojson.Safe.t =
  `Assoc [("jsonrpc", `String "2.0"); ("method", `String method_);
          ("params", params)]

let request id method_ params : Yojson.Safe.t =
  `Assoc [("jsonrpc", `String "2.0"); ("id", `Int id);
          ("method", `String method_); ("params", params)]

let did_open uri text =
  notif "textDocument/didOpen"
    (`Assoc [("textDocument",
              `Assoc [("uri", `String uri); ("languageId", `String "wand");
                      ("version", `Int 1); ("text", `String text)])])

let did_change uri text =
  notif "textDocument/didChange"
    (`Assoc [("textDocument", `Assoc [("uri", `String uri); ("version", `Int 2)]);
             ("contentChanges", `List [`Assoc [("text", `String text)]])])

let did_close uri =
  notif "textDocument/didClose"
    (`Assoc [("textDocument", `Assoc [("uri", `String uri)])])

(* Run a message sequence from the initial state, collecting every outgoing
   message in order. *)
let session msgs =
  let (st, outs) =
    List.fold_left (fun (st, acc) msg ->
      let (st, out) = Lsp.handle st msg in
      (st, acc @ out)
    ) (Lsp.initial, []) msgs
  in
  (st, outs)

let m = Lsp.mem
let s j = match Lsp.str j with Some s -> s | None -> Alcotest.fail "expected a string"
let int_of j = match j with `Int n -> n | _ -> Alcotest.fail "expected an int"

let diagnostics_of out =
  (* The one publishDiagnostics notification in `out` for each check. *)
  List.filter_map (fun o ->
    if Lsp.str (m "method" o) = Some "textDocument/publishDiagnostics"
    then Some (m "params" o) else None) out

let uri = "file:///tmp/wand_lsp_test.wand"

(* ── Lifecycle ───────────────────────────────────────────────────────────── *)

let test_initialize () =
  let (_, out) = session [request 1 "initialize" (`Assoc [])] in
  match out with
  | [resp] ->
    Alcotest.(check int) "answers the same id" 1 (int_of (m "id" resp));
    let caps = m "capabilities" (m "result" resp) in
    Alcotest.(check int) "full-text sync" 1
      (int_of (m "change" (m "textDocumentSync" caps)));
    Alcotest.(check string) "names itself" "wand"
      (s (m "name" (m "serverInfo" (m "result" resp))))
  | _ -> Alcotest.failf "expected exactly one response, got %d" (List.length out)

let test_shutdown_then_exit () =
  let (st, out) = session [request 2 "shutdown" `Null] in
  (match out with
   | [resp] -> Alcotest.(check bool) "result is null" true (m "result" resp = `Null)
   | _ -> Alcotest.fail "expected one response");
  (* A request after shutdown is the client's error. *)
  let (st, out) = Lsp.handle st (request 3 "initialize" `Null) in
  (match out with
   | [resp] ->
     Alcotest.(check int) "invalid request" (-32600)
       (int_of (m "code" (m "error" resp)))
   | _ -> Alcotest.fail "expected an error response");
  let (st, _) = Lsp.handle st (notif "exit" `Null) in
  Alcotest.(check (option int)) "clean exit" (Some 0) st.Lsp.quit

let test_exit_without_shutdown () =
  let (st, _) = session [notif "exit" `Null] in
  Alcotest.(check (option int)) "protocol error exit" (Some 1) st.Lsp.quit

let test_unknown_method () =
  let (_, out) = session [request 7 "workspace/symbol" `Null] in
  (match out with
   | [resp] ->
     Alcotest.(check int) "method not found" (-32601)
       (int_of (m "code" (m "error" resp)))
   | _ -> Alcotest.fail "expected an error response");
  let (_, out) = session [notif "$/cancelRequest" `Null] in
  Alcotest.(check int) "unknown notification ignored" 0 (List.length out)

(* ── Diagnostics ─────────────────────────────────────────────────────────── *)

let test_open_publishes_the_error () =
  let (_, out) = session [did_open uri "let x = 1\nlet y = x ++ \"s\"\n"] in
  match diagnostics_of out with
  | [params] ->
    Alcotest.(check string) "for the opened uri" uri (s (m "uri" params));
    (match m "diagnostics" params with
     | `List [d] ->
       Alcotest.(check string) "code" "E-TYPE" (s (m "code" d));
       Alcotest.(check int) "severity error" 1 (int_of (m "severity" d));
       Alcotest.(check string) "source" "wand" (s (m "source" d));
       (* 1-based 2:9-2:17 becomes 0-based 1:8-1:16 -- the whole
          expression at fault, not its first token. *)
       let range = m "range" d in
       Alcotest.(check (pair int int)) "start" (1, 8)
         (int_of (m "line" (m "start" range)),
          int_of (m "character" (m "start" range)));
       Alcotest.(check (pair int int)) "end" (1, 16)
         (int_of (m "line" (m "end" range)),
          int_of (m "character" (m "end" range)))
     | _ -> Alcotest.fail "expected exactly one diagnostic")
  | _ -> Alcotest.fail "expected one publishDiagnostics"

let test_findings_are_warnings () =
  let (_, out) = session [did_open uri "let is_ready? x = x > 1\nis_ready? 2\n"] in
  match diagnostics_of out with
  | [params] ->
    (match m "diagnostics" params with
     | `List [d] ->
       Alcotest.(check string) "code" "V-PRED2" (s (m "code" d));
       Alcotest.(check int) "severity warning" 2 (int_of (m "severity" d))
     | _ -> Alcotest.fail "expected exactly one diagnostic")
  | _ -> Alcotest.fail "expected one publishDiagnostics"

let test_change_republishes () =
  let (_, out) =
    session [
      did_open uri "let x = 1\nlet y = x ++ \"s\"\n";
      did_change uri "let x = \"1\"\nlet y = x ++ \"s\"\ny\n";
    ]
  in
  match diagnostics_of out with
  | [_; fixed] ->
    Alcotest.(check bool) "the fix clears the pane" true
      (m "diagnostics" fixed = `List [])
  | l -> Alcotest.failf "expected two publishes, got %d" (List.length l)

let test_close_clears () =
  let (st, out) =
    session [did_open uri "let x = 1 ++ 2\nx\n"; did_close uri]
  in
  Alcotest.(check bool) "the doc is forgotten" true
    (List.assoc_opt uri st.Lsp.docs = None);
  match List.rev (diagnostics_of out) with
  | last :: _ ->
    Alcotest.(check bool) "cleared on close" true
      (m "diagnostics" last = `List [])
  | [] -> Alcotest.fail "expected a clearing publish"

(* ── Framing ─────────────────────────────────────────────────────────────── *)

let test_framing_round_trip () =
  let path = Filename.temp_file "wand_lsp" ".bin" in
  Fun.protect ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
      let msg = request 9 "initialize" (`Assoc [("a", `String "b")]) in
      Out_channel.with_open_bin path (fun oc ->
        Lsp.write_message oc msg;
        Lsp.write_message oc (notif "exit" `Null));
      In_channel.with_open_bin path (fun ic ->
        (match Lsp.read_message ic with
         | Some j -> Alcotest.(check string) "first message survives"
                       (Yojson.Safe.to_string msg) (Yojson.Safe.to_string j)
         | None -> Alcotest.fail "no first message");
        (match Lsp.read_message ic with
         | Some j -> Alcotest.(check (option string)) "second too"
                       (Some "exit") (Lsp.str (m "method" j))
         | None -> Alcotest.fail "no second message");
        Alcotest.(check bool) "then the stream ends" true
          (Lsp.read_message ic = None)))

let () =
  Alcotest.run "lsp" [
    "lifecycle", [
      Alcotest.test_case "initialize"            `Quick test_initialize;
      Alcotest.test_case "shutdown then exit"    `Quick test_shutdown_then_exit;
      Alcotest.test_case "exit without shutdown" `Quick test_exit_without_shutdown;
      Alcotest.test_case "unknown method"        `Quick test_unknown_method;
    ];
    "diagnostics", [
      Alcotest.test_case "open publishes"     `Quick test_open_publishes_the_error;
      Alcotest.test_case "findings warn"      `Quick test_findings_are_warnings;
      Alcotest.test_case "change republishes" `Quick test_change_republishes;
      Alcotest.test_case "close clears"       `Quick test_close_clears;
    ];
    "framing", [
      Alcotest.test_case "round trip" `Quick test_framing_round_trip;
    ];
  ]
