open Wand

let run s = Runner.run_string s

let err label input =
  match run input with
  | Error _ -> ()
  | Ok s -> Alcotest.failf "%s: expected error but got: %s" label s

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let with_named name src f =
  let dir = Filename.get_temp_dir_name () in
  let path = Filename.concat dir (name ^ ".wand") in
  let oc = open_out path in
  output_string oc src; close_out oc;
  let result = (try f path with e -> Sys.remove path; raise e) in
  Sys.remove path; result

(* ── Private symbols (leading _) ─────────────────────────────────────────── *)

let test_private_symbols () =
  with_named "utils" {|let _secret = 42
let public = 1|} (fun path ->
    err "private symbol not accessible"
      (Printf.sprintf {|let utils = import %s
utils._secret|} path))

(* ── Error: missing field in destructure ────────────────────────────────── *)

let test_destructure_missing_field () =
  with_named "utils" {|let foo = 1|} (fun path ->
    err "missing field gives error"
      (Printf.sprintf {|let [bar = x] = import %s
x|} path))

(* ── User-path imports must state their binding ──────────────────────────── *)

(* A bare `import ./utils` used to bind `Utils`, a name derived by
   capitalising the filename. The two explicit forms below say what they
   bind, so they must keep working; the bare form must not. *)

let test_bare_user_import_rejected () =
  with_named "utils" {|let public = 1|} (fun path ->
    err "bare user-path import does not bind"
      (Printf.sprintf {|import %s
Utils.public|} path))

let test_explicit_binding_works () =
  with_named "utils" {|let public = 1|} (fun path ->
    Alcotest.(check (result string string))
      "let-bound import resolves"
      (Ok "1")
      (run (Printf.sprintf {|let utils = import %s
utils.public|} path)))

let test_destructured_binding_works () =
  with_named "utils" {|let public = 1|} (fun path ->
    Alcotest.(check (result string string))
      "destructured import resolves"
      (Ok "1")
      (run (Printf.sprintf {|let [public] = import %s
public|} path)))

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Imports" [
    "private", [
      Alcotest.test_case "private symbols" `Quick test_private_symbols;
    ];
    "errors", [
      Alcotest.test_case "missing field"   `Quick test_destructure_missing_field;
    ];
    "user paths", [
      Alcotest.test_case "bare import rejected"   `Quick test_bare_user_import_rejected;
      Alcotest.test_case "let binding works"      `Quick test_explicit_binding_works;
      Alcotest.test_case "destructuring works"    `Quick test_destructured_binding_works;
    ];
  ]
