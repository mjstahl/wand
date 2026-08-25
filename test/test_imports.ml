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
      (Printf.sprintf {|let {bar = x} = import %s
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
      (run (Printf.sprintf {|let {public} = import %s
public|} path)))

(* ── An import brings in what it names, and nothing else ─────────────────── *)

(* Binding a module to a name used to put every name inside it into scope
   unqualified as well, so `let m = import ./utils` quietly made `helper`
   callable as `helper`. That defeats the point of saying what an import
   binds: the name a reader greps for is not the name in the file. *)

let test_module_names_do_not_leak () =
  with_named "utils" {|let public = 1|} (fun path ->
    err "a name behind the module prefix is not in scope bare"
      (Printf.sprintf {|let utils = import %s
public|} path))

let test_destructuring_binds_only_what_it_names () =
  with_named "utils" {|let foo = 1
let bar = 2|} (fun path ->
    err "an unnamed field is not in scope"
      (Printf.sprintf {|let {foo} = import %s
bar|} path))

(* A module's own imports are its business. *)
let test_transitive_imports_do_not_leak () =
  with_named "utils" {|import List
let public = List.length [1, 2]|} (fun path ->
    err "the module's import does not become the importer's"
      (Printf.sprintf {|let utils = import %s
List.length [1]|} path))

(* A constructor is reached through the module that declares it, the way a
   value is. It used to arrive under its bare name, so two modules that each
   declared `Red` collided and no file could say which it meant. *)
let test_imported_constructors_cross () =
  with_named "colors" {|type Color = Red | Green
let pick = Red
let name c = match c with | Red -> "red" | Green -> "green"|} (fun path ->
    Alcotest.(check (result string string))
      "a constructor of an imported type is usable through the module"
      (Ok "green")
      (run (Printf.sprintf {|let colors = import %s
colors.name colors.Green|} path)))

(* And by being named in the import, which is how a value is brought in. *)
let test_imported_constructors_selected () =
  with_named "hues" {|type Hue = Warm | Cool
let name c = match c with | Warm -> "warm" | Cool -> "cool"|} (fun path ->
    Alcotest.(check (result string string))
      "a constructor named in the import is used bare"
      (Ok "warm")
      (run (Printf.sprintf {|let {name, Warm} = import %s
name Warm|} path)))

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
    "scope", [
      Alcotest.test_case "module names do not leak" `Quick test_module_names_do_not_leak;
      Alcotest.test_case "only what is named"       `Quick test_destructuring_binds_only_what_it_names;
      Alcotest.test_case "transitive do not leak"   `Quick test_transitive_imports_do_not_leak;
      Alcotest.test_case "constructors cross"       `Quick test_imported_constructors_cross;
      Alcotest.test_case "constructors selected"    `Quick test_imported_constructors_selected;
    ];
  ]
