open Wand

(* The REPL's tab completion, tested as the pure function it now is --
   line in, candidates out. Before the extraction this logic could only be
   exercised through linenoise, which needs a pty. *)

let contains_str l s = List.mem s l

(* A session with the stdlib imported, the way `wand i` starts. *)
let env () =
  let sess = Runner.make_session () in
  match Runner.run_session sess "import List\nlet frobnicate x = x" with
  | Ok (s, _) -> s.Runner.s_type_env
  | Error m -> Alcotest.failf "session setup failed: %s" m

let test_bare_ident () =
  let { Complete.start; candidates } = Complete.ident_at (env ()) "frob" in
  Alcotest.(check int) "starts at the beginning" 0 start;
  Alcotest.(check bool) "finds the binding" true
    (contains_str candidates "frobnicate")

let test_builtins_without_env () =
  let { Complete.candidates; _ } = Complete.ident_at [] "prin" in
  Alcotest.(check bool) "print" true (contains_str candidates "print");
  Alcotest.(check bool) "println" true (contains_str candidates "println")

let test_namespace_member () =
  let { Complete.start; candidates } =
    Complete.ident_at (env ()) "let xs = List.fil" in
  Alcotest.(check int) "starts after the space" 9 start;
  Alcotest.(check bool) "List.filter" true
    (contains_str candidates "List.filter")

let test_unknown_namespace () =
  let { Complete.candidates; _ } = Complete.ident_at (env ()) "Nope.x" in
  Alcotest.(check (list string)) "nothing to offer" [] candidates

let test_two_dots () =
  let { Complete.candidates; _ } = Complete.ident_at (env ()) "a.b.c" in
  Alcotest.(check (list string)) "nothing to offer" [] candidates

let test_whole_line_rebuilt () =
  let lines = Complete.line_completions (env ()) "let xs = List.fil" in
  Alcotest.(check bool) "the candidate replaces only the identifier" true
    (contains_str lines "let xs = List.filter")

let test_command_names () =
  let lines = Complete.line_completions [] ":e" in
  Alcotest.(check bool) ":edit" true (contains_str lines ":edit");
  Alcotest.(check bool) ":env" true (contains_str lines ":env");
  Alcotest.(check bool) "no unrelated command" false (contains_str lines ":load")

let test_command_ident_arg () =
  let lines = Complete.line_completions (env ()) ":t Li" in
  Alcotest.(check bool) "the namespace itself" true
    (contains_str lines ":t List");
  let lines = Complete.line_completions (env ()) ":d List.len" in
  Alcotest.(check bool) "a member after :d" true
    (contains_str lines ":d List.length")

let () =
  Alcotest.run "completion" [
    "identifiers", [
      Alcotest.test_case "a bare prefix"          `Quick test_bare_ident;
      Alcotest.test_case "builtins, empty env"    `Quick test_builtins_without_env;
      Alcotest.test_case "a namespace member"     `Quick test_namespace_member;
      Alcotest.test_case "an unknown namespace"   `Quick test_unknown_namespace;
      Alcotest.test_case "two dots"               `Quick test_two_dots;
    ];
    "lines", [
      Alcotest.test_case "whole line rebuilt"     `Quick test_whole_line_rebuilt;
      Alcotest.test_case "command names"          `Quick test_command_names;
      Alcotest.test_case "a command's identifier" `Quick test_command_ident_arg;
    ];
  ]
