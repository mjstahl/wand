open Wand

(* `wand t --json` is consumed by machines, so the schema is locked here as
   golden strings: severity, code, file, line, col, message, and a `fix`
   payload wherever the compiler already computes the correction. Breaking
   one of these strings means breaking every consumer. *)

let golden = Alcotest.(check string)

let findings src =
  let sess = Runner.make_session () in
  match Runner.lint_session sess src with
  | Ok fs -> fs
  | Error m -> Alcotest.failf "lint failed: %s\nsource:\n%s" m src

(* ── Findings ─────────────────────────────────────────────────────────────── *)

let test_manifest_fix () =
  golden "A-USES2 carries insert_line"
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
   the original object shape -- the golden above locks that. *)
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
  golden "a typed hole is its own shape"
    "[{\"kind\":\"hole\",\"type\":\"Int -> Int -> Int ! 'e\"}]"
    (Lint.diagnostics_json ~strict:false ~holes:["Int -> Int -> Int ! 'e"] [])

(* ── Errors ───────────────────────────────────────────────────────────────── *)

(* Errors reach the JSON as `Diag.t` values whose position travelled from
   the raise site as data. Nothing here (or anywhere) recovers a position
   by parsing a message string. *)

let check_error src =
  match Runner.typecheck_source ~path:"wand_json_err.wand" src with
  | Error d -> d
  | Ok _ -> Alcotest.failf "expected an error from:\n%s" src

let test_type_error () =
  golden "type error with its position carried as data"
    "[{\"severity\":\"error\",\"code\":\"E-TYPE\",\"line\":1,\"col\":5,\
      \"message\":\"cannot unify String with Int\"}]"
    (Diag.to_json_array
       [Diag.error ~code:"E-TYPE" ~loc:(Token.point 1 5 4)
          "cannot unify String with Int"])

let test_error_without_position () =
  golden "an error with no position reports 1:1, drift fix carried"
    "[{\"severity\":\"error\",\"code\":\"E-LEX\",\"file\":\"x.wand\",\
      \"line\":1,\"col\":1,\
      \"message\":\"cons is a single ':', not '::' -- \
      h : rest to build a list, [h : t] in a pattern\",\
      \"fix\":{\"replace\":{\"from\":\"::\",\"to\":\":\"}}}]"
    (Diag.to_json_array ~file:"x.wand"
       [Diag.error ~code:"E-LEX"
          "cons is a single ':', not '::' -- \
           h : rest to build a list, [h : t] in a pattern"])

(* End to end: the checker's answer carries the real position. *)

let test_lex_error_position () =
  let d = check_error "let x =\n  1 :: 2" in
  Alcotest.(check string) "code" "E-LEX" d.Diag.code;
  (match d.Diag.loc with
   | Some l -> Alcotest.(check (pair int int)) "line/col of the '::'"
                 (2, 5) (l.Token.line, l.Token.col)
   | None -> Alcotest.fail "lex error lost its position");
  (match d.Diag.fix with
   | Some (Lint.Replace { from_ = "::"; to_ = ":" }) -> ()
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
