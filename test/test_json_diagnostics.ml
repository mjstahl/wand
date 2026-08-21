open Wand

(* `wand t --json` is consumed by machines, so the schema is locked here as
   exact strings: severity, code, file, line, col, message, and a `fix`
   payload wherever the compiler already computes the correction. Breaking
   one of these strings means breaking every consumer. *)

let regression = Alcotest.(check string)

let findings src =
  let sess = Runner.make_session () in
  match Runner.lint_session sess src with
  | Ok fs -> fs
  | Error m -> Alcotest.failf "lint failed: %s\nsource:\n%s" m src

(* ── Findings ─────────────────────────────────────────────────────────────── *)

let test_manifest_fix () =
  regression "A-USES2 carries insert_line"
    "[{\"severity\":\"warning\",\"code\":\"A-USES2\",\"line\":1,\"col\":1,\
      \"message\":\"this file performs FS.Write and does not say so; it \
      could declare \\\"uses {FS.Write}\\\"\",\
      \"fix\":{\"insert_line\":\"uses {FS.Write}\"}}]"
    (Lint.diagnostics_json ~strict:false ~holes:[]
       (findings "import FS\nlet f p = FS.write_file p \"x\"\nf /tmp/y"))

let test_uses1_replace_line () =
  let fs =
    findings "uses {Shell, FS.Write}\nimport FS\nlet f p = FS.write_file p \"x\"\nf /tmp/y"
  in
  let json = Lint.diagnostics_json ~strict:false ~holes:[] fs in
  if not (Lint.contains json "\"fix\":{\"replace_line\":\"uses {FS.Write}\"}") then
    Alcotest.failf "A-USES1 lacks replace_line fix:\n%s" json

let test_strict_severity () =
  let fs =
    findings
      "uses {FS.Write, IO}\nimport FS\nimport IO\n\
       FS.write_file /tmp/x.txt \"hi\"\nIO.println \"done\""
  in
  let strict = Lint.diagnostics_json ~strict:true ~holes:[] fs in
  let lax = Lint.diagnostics_json ~strict:false ~holes:[] fs in
  if not (Lint.contains strict "\"severity\":\"error\",\"code\":\"V-DROP1\"") then
    Alcotest.failf "V-DROP1 not an error under --strict:\n%s" strict;
  if Lint.contains lax "\"severity\":\"error\"" then
    Alcotest.failf "errors reported without --strict:\n%s" lax

let test_file_field () =
  let json =
    Lint.diagnostics_json ~strict:false ~file:"deploy.wand" ~holes:[]
      (findings "import FS\nlet f p = FS.write_file p \"x\"\nf /tmp/y")
  in
  if not (Lint.contains json "\"code\":\"A-USES2\",\"file\":\"deploy.wand\",") then
    Alcotest.failf "file field missing or misplaced:\n%s" json

(* A finding marks the whole item it is about, and the range rides along
   as end_line/end_col. A point diagnostic (like A-USES2's line 1) keeps
   the original object shape -- the check above locks that. *)
let test_finding_range () =
  let json =
    Lint.diagnostics_json ~strict:false ~holes:[]
      (findings "let is_ready? x = x > 1\nis_ready? 2")
  in
  if not (Lint.contains json
            "\"line\":1,\"col\":1,\"end_line\":1,\"end_col\":24,") then
    Alcotest.failf "V-PRED2 does not span its item:\n%s" json

(* ── Holes ────────────────────────────────────────────────────────────────── *)

let test_hole_shape () =
  regression "a typed hole is its own shape"
    "[{\"kind\":\"hole\",\"type\":\"Int -> Int -> Int ! 'e\"}]"
    (Lint.diagnostics_json ~strict:false ~holes:["Int -> Int -> Int ! 'e"] [])

(* ── Query commands (`wand d --json`, `wand v --json`) ───────────────────── *)

let query_sess src =
  let sess = Runner.make_session () in
  match Runner.run_session sess src with
  | Ok (s, _) -> s
  | Error m -> Alcotest.failf "session load failed: %s\nsource:\n%s" m src

let test_doc_json () =
  let sess =
    query_sess "(** Doubles a number. *)\nlet double x = x * 2"
  in
  regression "doc as one object"
    "{\"name\":\"double\",\"type\":\"Int -> Int\",\
      \"doc\":\"Doubles a number.\"}"
    (Runner.doc_json sess "double")

let test_doc_json_absent () =
  let sess = query_sess "let x = 1" in
  regression "a missing doc and type are null, not omitted"
    "{\"name\":\"nope\",\"type\":null,\"doc\":null}"
    (Runner.doc_json sess "nope")

let test_scope_json () =
  let sess = query_sess "import List\nlet greet name = \"hi %{name}\"" in
  let json = Runner.scope_json sess in
  if not (Lint.contains json "{\"name\":\"List\",\"module\":true}") then
    Alcotest.failf "module entry missing:\n%s" json;
  if not (Lint.contains json
            "{\"name\":\"greet\",\"type\":\"'a -> String\"}") then
    Alcotest.failf "binding entry missing:\n%s" json

let test_scope_json_empty () =
  regression "an empty scope is an empty array"
    "[]" (Runner.scope_json (Runner.make_session ()))

let test_module_json () =
  let sess = query_sess "import List" in
  (match Runner.module_json sess "List" with
   | Ok json ->
     if not (Lint.contains json "{\"name\":\"List.length\",\"type\":") then
       Alcotest.failf "qualified member missing:\n%s" json
   | Error m -> Alcotest.failf "module_json List failed: %s" m);
  (match Runner.module_json sess "Nope" with
   | Error "Unknown module 'Nope'" -> ()
   | Error m -> Alcotest.failf "unexpected message: %s" m
   | Ok _ -> Alcotest.fail "expected an error for an unknown module");
  let sess = query_sess "let x = 1" in
  match Runner.module_json sess "x" with
  | Error "x is a binding, not a module" -> ()
  | Error m -> Alcotest.failf "unexpected message: %s" m
  | Ok _ -> Alcotest.fail "expected an error for a binding"

(* ── Test runs (`wand s --json`) ──────────────────────────────────────────── *)

let test_run_json () =
  regression "a test run is one object; error status still counts as failed"
    "{\"tests\":[\
       {\"file\":\"test_a.wand\",\"status\":\"pass\",\"label\":\"it adds\"},\
       {\"file\":\"test_a.wand\",\"status\":\"fail\",\
        \"message\":\"it fails: expected 4, got 3\"},\
       {\"file\":\"test_a.wand\",\"status\":\"error\",\
        \"message\":\"pattern match failure\"}],\
      \"errors\":[{\"file\":\"test_b.wand\",\
        \"message\":\"parse error: 2:1: unexpected token: EOF\"}],\
      \"passed\":1,\"failed\":2}"
    (Runner.test_results_json
       [("test_a.wand",
         Ok [Runner.TPass "it adds";
             Runner.TFail "it fails: expected 4, got 3";
             Runner.TError "pattern match failure"]);
        ("test_b.wand", Error "parse error: 2:1: unexpected token: EOF")])

let test_run_json_empty () =
  regression "no tests, no errors"
    "{\"tests\":[],\"errors\":[],\"passed\":0,\"failed\":0}"
    (Runner.test_results_json [])

(* ── Errors ───────────────────────────────────────────────────────────────── *)

(* Errors reach the JSON as `Diag.t` values whose position travelled from
   the raise site as data. Nothing here (or anywhere) recovers a position
   by parsing a message string. *)

let check_error src =
  match Runner.typecheck_source ~path:"wand_json_err.wand" src with
  | Error d -> d
  | Ok _ -> Alcotest.failf "expected an error from:\n%s" src

let test_type_error () =
  regression "type error with its position carried as data"
    "[{\"severity\":\"error\",\"code\":\"E-TYPE\",\"line\":1,\"col\":5,\
      \"message\":\"expected String, got Int\"}]"
    (Diag.to_json_array
       [Diag.error ~code:"E-TYPE" ~loc:(Token.point 1 5 4)
          "expected String, got Int"])

let test_error_without_position () =
  regression "an error with no position reports 1:1, drift fix carried"
    "[{\"severity\":\"error\",\"code\":\"E-LEX\",\"file\":\"x.wand\",\
      \"line\":1,\"col\":1,\
      \"message\":\"comments are '-- ...' to the end of the line, or \
      '(* ... *)' -- not '//'\",\
      \"fix\":{\"replace\":{\"from\":\"//\",\"to\":\"--\"}}}]"
    (Diag.to_json_array ~file:"x.wand"
       [Diag.error ~code:"E-LEX"
          "comments are '-- ...' to the end of the line, or \
           '(* ... *)' -- not '//'"])

(* End to end: the checker's answer carries the real position. *)

let test_lex_error_position () =
  let d = check_error "let x =\n  1 // 2" in
  Alcotest.(check string) "code" "E-LEX" d.Diag.code;
  (match d.Diag.loc with
   | Some l -> Alcotest.(check (pair int int)) "line/col of the '//'"
                 (2, 5) (l.Token.line, l.Token.col)
   | None -> Alcotest.fail "lex error lost its position");
  (match d.Diag.fix with
   | Some (Lint.Replace { from_ = "//"; to_ = "--" }) -> ()
   | _ -> Alcotest.fail "drift fix not carried")

let test_parse_error_position () =
  let d = check_error "let x = (1\n" in
  Alcotest.(check string) "code" "E-PARSE" d.Diag.code;
  if d.Diag.loc = None then Alcotest.fail "parse error lost its position"

let test_type_error_position () =
  let d = check_error "let x = 1\nlet y = x ++ \"s\"" in
  Alcotest.(check string) "code" "E-TYPE" d.Diag.code;
  (match d.Diag.loc with
   | Some l -> Alcotest.(check int) "points into line 2" 2 l.Token.line
   | None -> Alcotest.fail "type error lost its position")

(* The loc of a type error spans the whole expression the nearest `Located`
   wraps, not just its first token -- `x ++ "s"` is columns 9 through 16. *)
let test_type_error_range () =
  let d = check_error "let x = 1\nlet y = x ++ \"s\"" in
  match d.Diag.loc with
  | Some l ->
    Alcotest.(check (pair int int)) "start" (2, 9) (l.Token.line, l.Token.col);
    Alcotest.(check (pair int int)) "end (exclusive)"
      (2, 17) (l.Token.end_line, l.Token.end_col)
  | None -> Alcotest.fail "type error lost its position"

let test_parse_error_drift_fix () =
  let d = check_error "1\nx and y" in
  let json = Diag.to_json_array [d] in
  if not (Lint.contains json "\"code\":\"E-PARSE\"") then
    Alcotest.failf "expected E-PARSE:\n%s" json;
  if not (Lint.contains json
            "\"fix\":{\"replace\":{\"from\":\"and\",\"to\":\"&&\"}}") then
    Alcotest.failf "drift fix missing:\n%s" json


(* ── The exit code is part of the contract ──────────────────────────────── *)

(* `--strict` says a violation ends the command in failure, and a CI step
   reads that from the exit code. Under `--json` the code stayed 0 while the
   JSON itself called the finding an error, so the step passed on a file the
   same command had just failed. These run the real binary, since the exit
   code is the CLI's answer and nothing below it can be asked. *)

let wand_binary =
  let dir = Filename.dirname (Filename.dirname Sys.executable_name) in
  Filename.concat (Filename.concat dir "bin") "wand.exe"

let run args =
  let cmd = String.concat " " (List.map Filename.quote (wand_binary :: args)) in
  let ic = Unix.open_process_in (cmd ^ " 2>/dev/null") in
  let out = In_channel.input_all ic in
  let code = match Unix.close_process_in ic with
    | Unix.WEXITED n -> n
    | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n
  in
  (code, String.trim out)

(* V-SHELL1: a command word decided at run time under a narrowed manifest. *)
let violating_file () =
  let path = Filename.temp_file "wand_strict" ".wand" in
  Out_channel.with_open_text path (fun oc ->
    Out_channel.output_string oc "uses {Shell(git)}\n\nlet run! cmd = $(git %!{cmd})\n");
  path

let with_violating_file f =
  let path = violating_file () in
  Fun.protect ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () -> f path)

let test_strict_json_exit_code () =
  with_violating_file (fun path ->
    let (code, out) = run ["t"; "--strict"; "--json"; "--file"; path] in
    if not (Lint.contains out "\"severity\":\"error\"") then
      Alcotest.failf "the finding was not reported as an error:\n%s" out;
    Alcotest.(check int) "--strict --json fails on a violation" 1 code)

let test_strict_text_exit_code () =
  with_violating_file (fun path ->
    let (code, _) = run ["t"; "--strict"; "--file"; path] in
    Alcotest.(check int) "and says the same without --json" 1 code)

let test_json_without_strict_is_a_warning () =
  with_violating_file (fun path ->
    let (code, out) = run ["t"; "--json"; "--file"; path] in
    if not (Lint.contains out "\"severity\":\"warning\"") then
      Alcotest.failf "expected a warning without --strict:\n%s" out;
    Alcotest.(check int) "a warning is not a failure" 0 code)

let test_strict_json_expression () =
  (* The same rule for an expression, which takes a different path through
     the CLI than a file does. *)
  let (code, out) = run ["t"; "--strict"; "--json"; "let big? n = n + 1"] in
  if not (Lint.contains out "V-PRED1") then
    Alcotest.failf "expected V-PRED1:\n%s" out;
  Alcotest.(check int) "--strict --json fails on an expression too" 1 code

let test_strict_json_clean_file () =
  let path = Filename.temp_file "wand_clean" ".wand" in
  Out_channel.with_open_text path (fun oc ->
    Out_channel.output_string oc "let double n = n * 2\n");
  Fun.protect ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
       let (code, _) = run ["t"; "--strict"; "--json"; "--file"; path] in
       Alcotest.(check int) "a clean file still passes" 0 code)

let () =
  Alcotest.run "json diagnostics" [
    "findings", [
      Alcotest.test_case "manifest insert_line"  `Quick test_manifest_fix;
      Alcotest.test_case "manifest replace_line" `Quick test_uses1_replace_line;
      Alcotest.test_case "strict severity"       `Quick test_strict_severity;
      Alcotest.test_case "file field"            `Quick test_file_field;
      Alcotest.test_case "item range"            `Quick test_finding_range;
    ];
    "holes", [
      Alcotest.test_case "shape" `Quick test_hole_shape;
    ];
    "queries", [
      Alcotest.test_case "doc"         `Quick test_doc_json;
      Alcotest.test_case "doc absent"  `Quick test_doc_json_absent;
      Alcotest.test_case "scope"       `Quick test_scope_json;
      Alcotest.test_case "scope empty" `Quick test_scope_json_empty;
      Alcotest.test_case "module"      `Quick test_module_json;
    ];
    "test runs", [
      Alcotest.test_case "run"   `Quick test_run_json;
      Alcotest.test_case "empty" `Quick test_run_json_empty;
    ];
    "exit codes", [
      Alcotest.test_case "--strict --json"       `Quick test_strict_json_exit_code;
      Alcotest.test_case "--strict"              `Quick test_strict_text_exit_code;
      Alcotest.test_case "no --strict"           `Quick test_json_without_strict_is_a_warning;
      Alcotest.test_case "an expression"         `Quick test_strict_json_expression;
      Alcotest.test_case "a clean file"          `Quick test_strict_json_clean_file;
    ];
    "errors", [
      Alcotest.test_case "type"            `Quick test_type_error;
      Alcotest.test_case "no position"     `Quick test_error_without_position;
      Alcotest.test_case "lex position"    `Quick test_lex_error_position;
      Alcotest.test_case "parse position"  `Quick test_parse_error_position;
      Alcotest.test_case "type position"   `Quick test_type_error_position;
      Alcotest.test_case "type range"      `Quick test_type_error_range;
      Alcotest.test_case "parse + fix"     `Quick test_parse_error_drift_fix;
    ];
  ]
