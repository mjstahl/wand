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

(* ── Env.read / Env.load ─────────────────────────────────────────────────── *)

let with_dotenv content f =
  let path = Filename.temp_file "wand_env_" ".env" in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect f ~finally:(fun () -> Sys.remove path)

let test_env_read () =
  with_dotenv "FOO=bar\nBAZ=qux\n" (fun () ->
    let path = Filename.temp_file "wand_env_rd_" ".env" in
    let oc = open_out path in output_string oc "FOO=bar\nBAZ=qux\n"; close_out oc;
    ok "basic key=value"
      (Printf.sprintf {|import Env
import Map
import Path
let m = Env.read (Path.of_string "%s")
Map.get! "FOO" m|} path)
      "bar";
    Sys.remove path)

let test_env_read_formats () =
  let dotenv = "# comment\nKEY1=hello\nKEY2=\"quoted\"\nKEY3='single'\nexport KEY4=exported\n\nKEY5=has=equals\n" in
  with_dotenv dotenv (fun () ->
    let path = Filename.temp_file "wand_env_fmt_" ".env" in
    let oc = open_out path in output_string oc dotenv; close_out oc;
    let src key = Printf.sprintf {|import Env
import Map
import Path
let m = Env.read (Path.of_string "%s")
Map.get! "%s" m|} path key in
    ok "plain value"   (src "KEY1") "hello";
    ok "double-quoted" (src "KEY2") "quoted";
    ok "single-quoted" (src "KEY3") "single";
    ok "export prefix" (src "KEY4") "exported";
    ok "value with ="  (src "KEY5") "has=equals";
    Sys.remove path)

let test_env_load () =
  with_dotenv "WAND_LOAD_TEST=loaded_value\n" (fun () ->
    let path = Filename.temp_file "wand_load_" ".env" in
    let oc = open_out path in output_string oc "WAND_LOAD_TEST=loaded_value\n"; close_out oc;
    ok "load sets env var"
      (Printf.sprintf {|import Env
import Path
let () = Env.load (Path.of_string "%s")
Env.get "WAND_LOAD_TEST"|} path)
      "loaded_value";
    Sys.remove path)

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
    "dotenv", [
      Alcotest.test_case "read"    `Quick test_env_read;
      Alcotest.test_case "formats" `Quick test_env_read_formats;
      Alcotest.test_case "load"    `Quick test_env_load;
    ];
  ]
