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

(* ── Holes ────────────────────────────────────────────────────────────────── *)

let test_hole_shape () =
  golden "a typed hole is its own shape"
    "[{\"kind\":\"hole\",\"type\":\"Int -> Int -> Int ! 'e\"}]"
    (Lint.diagnostics_json ~strict:false ~holes:["Int -> Int -> Int ! 'e"] [])

(* ── Errors ───────────────────────────────────────────────────────────────── *)

let test_type_error () =
  golden "type error with position lifted out"
    "[{\"severity\":\"error\",\"code\":\"E-TYPE\",\"line\":1,\"col\":5,\
      \"message\":\"cannot unify String with Int\"}]"
    (Lint.error_to_json "type error: 1:5: cannot unify String with Int")

let test_lex_error_without_position () =
  golden "lex error, no position, drift fix carried"
    "[{\"severity\":\"error\",\"code\":\"E-LEX\",\"file\":\"x.wand\",\
      \"line\":1,\"col\":1,\
      \"message\":\"'::' is OCaml's cons; in wand it is a single ':' -- \
      h : rest to build a list, [h : t] in a pattern\",\
      \"fix\":{\"replace\":{\"from\":\"::\",\"to\":\":\"}}}]"
    (Lint.error_to_json ~file:"x.wand"
       "lex error: '::' is OCaml's cons; in wand it is a single ':' -- \
        h : rest to build a list, [h : t] in a pattern")

let test_parse_error_drift_fix () =
  let json =
    Lint.error_to_json
      "parse error: 1:6: unexpected token: and -- the boolean operator is \
       '&&'; wand's 'and' only joins mutually recursive let bindings"
  in
  if not (Lint.contains json "\"code\":\"E-PARSE\",\"line\":1,\"col\":6") then
    Alcotest.failf "parse error position not lifted:\n%s" json;
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
    ];
    "holes", [
      Alcotest.test_case "shape" `Quick test_hole_shape;
    ];
    "errors", [
      Alcotest.test_case "type"        `Quick test_type_error;
      Alcotest.test_case "lex + fix"   `Quick test_lex_error_without_position;
      Alcotest.test_case "parse + fix" `Quick test_parse_error_drift_fix;
    ];
  ]
