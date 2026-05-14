open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

let err label input =
  match run input with
  | Error _ -> ()
  | Ok s -> Alcotest.failf "%s: expected error but got: %s" label s

(* ── String concatenation ────────────────────────────────────────────────── *)

let test_concat () =
  ok "simple concat"
    {|"hello" ++ " world"|}
    "hello world";
  ok "concat with var"
    {|let name = "Alice"
"Hello, " ++ name ++ "!"|}
    "Hello, Alice!";
  ok "concat empty"
    {|"" ++ "abc"|}
    "abc"

let test_concat_errors () =
  err "int ++ string" {|1 ++ "a"|};
  err "string ++ int" {|"a" ++ 1|}

(* ── String interpolation ────────────────────────────────────────────────── *)

let test_interp () =
  ok "simple interp"
    {|let name = "World"
"Hello, ${name}!"|}
    "Hello, World!";
  ok "interp arithmetic"
    {|"1 + 2 = ${1 + 2}"|}
    "1 + 2 = 3";
  ok "interp bool"
    {|"flag: ${true}"|}
    "flag: true";
  ok "no interp"
    {|"plain string"|}
    "plain string";
  ok "multiple interps"
    {|let x = "a"
let y = "b"
"${x} and ${y}"|}
    "a and b"

let test_interp_errors () =
  err "bad expr in interp" {|"${1 + true}"|}

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Strings" [
    "concatenation", [
      Alcotest.test_case "concat"        `Quick test_concat;
      Alcotest.test_case "concat errors" `Quick test_concat_errors;
    ];
    "interpolation", [
      Alcotest.test_case "interp"        `Quick test_interp;
      Alcotest.test_case "interp errors" `Quick test_interp_errors;
    ];
  ]
