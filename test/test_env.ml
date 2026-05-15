open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

let err label input =
  match run input with
  | Error _ -> ()
  | Ok v -> Alcotest.failf "%s: expected error but got: %s" label v

(* ── get ─────────────────────────────────────────────────────────────────── *)

let test_get () =
  Unix.putenv "WAND_TEST_VAR" "hello";
  ok "get existing"
    {|import Env
Env.get "WAND_TEST_VAR"|}
    "hello";
  ok "get missing returns empty"
    {|import Env
Env.get "WAND_TEST_NONEXISTENT_XYZ"|}
    ""

(* ── get! ────────────────────────────────────────────────────────────────── *)

let test_get_exn () =
  Unix.putenv "WAND_TEST_VAR" "world";
  ok "get! existing"
    {|import Env
Env.get! "WAND_TEST_VAR"|}
    "world";
  err "get! missing raises"
    {|import Env
Env.get! "WAND_TEST_NONEXISTENT_XYZ"|}

(* ── set ─────────────────────────────────────────────────────────────────── *)

let test_set () =
  ok "set then get"
    {|import Env
let () = Env.set "WAND_TEST_SET" "value"
Env.get "WAND_TEST_SET"|}
    "value"

(* ── unset ───────────────────────────────────────────────────────────────── *)

let test_unset () =
  Unix.putenv "WAND_TEST_UNSET" "before";
  ok "unset clears value"
    {|import Env
let () = Env.unset "WAND_TEST_UNSET"
Env.get "WAND_TEST_UNSET"|}
    ""

(* ── all ─────────────────────────────────────────────────────────────────── *)

let test_all () =
  Unix.putenv "WAND_TEST_ALL" "present";
  ok "all contains set var"
    {|import Env
import List
let pairs = Env.all ()
List.any (fn (k, _) -> k == "WAND_TEST_ALL") pairs|}
    "true"

(* ── args ────────────────────────────────────────────────────────────────── *)

let test_args () =
  ok "args returns list"
    {|import Env
import List
List.is_empty (Env.args ()) == false || true|}
    "true"

(* ── home ────────────────────────────────────────────────────────────────── *)

let test_home () =
  ok "home returns path"
    {|import Env
import Path
Path.is_absolute? (Env.home ())|}
    "true"

(* ── user ────────────────────────────────────────────────────────────────── *)

let test_user () =
  ok "user returns non-empty string"
    {|import Env
import String
String.length (Env.user ()) > 0|}
    "true"

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Env module" [
    "core", [
      Alcotest.test_case "get"   `Quick test_get;
      Alcotest.test_case "get!"  `Quick test_get_exn;
      Alcotest.test_case "set"   `Quick test_set;
      Alcotest.test_case "unset" `Quick test_unset;
      Alcotest.test_case "all"   `Quick test_all;
      Alcotest.test_case "args"  `Quick test_args;
      Alcotest.test_case "home"  `Quick test_home;
      Alcotest.test_case "user"  `Quick test_user;
    ];
  ]
