open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

let err label input =
  match run input with
  | Error _ -> ()
  | Ok v -> Alcotest.failf "%s: expected error but got: %s" label v

(* ── parse ───────────────────────────────────────────────────────────────── *)

let test_parse () =
  ok "valid TOML returns Ok"
    {|import TOML
match TOML.parse "key = \"value\"\n" with
| Ok _    -> "ok"
| Error _ -> "error"|}
    "ok";
  ok "invalid TOML returns Error"
    {|import TOML
match TOML.parse "not = = toml" with
| Ok _    -> "ok"
| Error _ -> "error"|}
    "error"

let test_parse_exn () =
  ok "parse! valid"
    {|import TOML
let t = TOML.parse! "x = 1\n"
TOML.is_table t|}
    "true";
  err "parse! invalid raises"
    {|import TOML
TOML.parse! "bad = = toml"|}

(* ── field / field! ──────────────────────────────────────────────────────── *)

let test_field () =
  ok "field exists"
    {|import TOML
let t = TOML.parse! "name = \"Alice\"\nage = 30\n"
match TOML.field "name" t with
| Ok v  -> TOML.get_string v
| Error _ -> Error "no field"|}
    "Ok(Alice)";
  ok "field missing"
    {|import TOML
let t = TOML.parse! "a = 1\n"
match TOML.field "z" t with
| Ok _    -> "ok"
| Error _ -> "error"|}
    "error";
  ok "field! exists"
    {|import TOML
let t = TOML.parse! "x = 42\n"
match TOML.get_int (TOML.field! "x" t) with
| Ok n  -> n
| Error _ -> -1|}
    "42";
  err "field! missing raises"
    {|import TOML
let t = TOML.parse! "a = 1\n"
TOML.field! "z" t|}

(* ── get_* extractors ────────────────────────────────────────────────────── *)

let test_get_string () =
  ok "get_string"
    {|import TOML
let t = TOML.parse! "s = \"hello\"\n"
match TOML.get_string (TOML.field! "s" t) with
| Ok s  -> s
| Error _ -> ""|}
    "hello"

let test_get_int () =
  ok "get_int"
    {|import TOML
let t = TOML.parse! "n = 99\n"
match TOML.get_int (TOML.field! "n" t) with
| Ok n  -> n
| Error _ -> -1|}
    "99"

let test_get_float () =
  ok "get_float"
    {|import TOML
let t = TOML.parse! "f = 3.14\n"
match TOML.get_float (TOML.field! "f" t) with
| Ok f  -> f > 3.0
| Error _ -> false|}
    "true";
  ok "get_float from int"
    {|import TOML
let t = TOML.parse! "n = 2\n"
match TOML.get_float (TOML.field! "n" t) with
| Ok f  -> f == 2.0
| Error _ -> false|}
    "true"

let test_get_bool () =
  ok "get_bool true"
    {|import TOML
let t = TOML.parse! "flag = true\n"
match TOML.get_bool (TOML.field! "flag" t) with
| Ok b  -> b
| Error _ -> false|}
    "true"

let test_get_array () =
  ok "get_array length"
    {|import TOML
import List
let t = TOML.parse! "nums = [1, 2, 3]\n"
match TOML.get_array (TOML.field! "nums" t) with
| Ok xs -> List.length xs
| Error _ -> -1|}
    "3";
  ok "get_array int elements"
    {|import TOML
import List
let t = TOML.parse! "nums = [10, 20]\n"
match TOML.get_array (TOML.field! "nums" t) with
| Ok xs ->
  match TOML.get_int (List.head xs) with
  | Ok n  -> n
  | Error _ -> -1
| Error _ -> -1|}
    "10"

(* ── nested tables ───────────────────────────────────────────────────────── *)

let test_nested () =
  ok "nested table access"
    {|import TOML
let src = "[server]\nhost = \"localhost\"\nport = 8080\n"
let t = TOML.parse! src
let server = TOML.field! "server" t
match TOML.get_string (TOML.field! "host" server) with
| Ok s  -> s
| Error _ -> ""|}
    "localhost"

(* ── get_table ───────────────────────────────────────────────────────────── *)

let test_get_table () =
  ok "get_table returns Map"
    {|import TOML
import Map
let t = TOML.parse! "a = 1\nb = 2\n"
match TOML.get_table t with
| Ok m  -> Map.size m
| Error _ -> -1|}
    "2"

(* ── read_file ───────────────────────────────────────────────────────────── *)

let with_toml content f =
  let path = Filename.temp_file "wand_toml_" ".toml" in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect f ~finally:(fun () -> Sys.remove path)

let test_read_file () =
  with_toml "[db]\nname = \"mydb\"\n" (fun () ->
    let path = Filename.temp_file "wand_toml_rd_" ".toml" in
    let oc = open_out path in
    output_string oc "[db]\nname = \"mydb\"\n";
    close_out oc;
    ok "read_file ok"
      (Printf.sprintf {|import TOML
import Path
match TOML.read_file (Path.of_string "%s") with
| Ok t  ->
  let db = TOML.field! "db" t
  match TOML.get_string (TOML.field! "name" db) with
  | Ok s  -> s
  | Error _ -> ""
| Error _ -> ""|}  path)
      "mydb";
    Sys.remove path)

let test_read_file_missing () =
  ok "missing file returns Error"
    {|import TOML
import Path
match TOML.read_file (Path.of_string "/nonexistent/wand_missing.toml") with
| Ok _    -> "ok"
| Error _ -> "error"|}
    "error"

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "TOML module" [
    "parse", [
      Alcotest.test_case "parse"     `Quick test_parse;
      Alcotest.test_case "parse_exn" `Quick test_parse_exn;
    ];
    "field", [
      Alcotest.test_case "field"     `Quick test_field;
    ];
    "get", [
      Alcotest.test_case "string"    `Quick test_get_string;
      Alcotest.test_case "int"       `Quick test_get_int;
      Alcotest.test_case "float"     `Quick test_get_float;
      Alcotest.test_case "bool"      `Quick test_get_bool;
      Alcotest.test_case "array"     `Quick test_get_array;
      Alcotest.test_case "table"     `Quick test_get_table;
    ];
    "nested", [
      Alcotest.test_case "nested"    `Quick test_nested;
    ];
    "read_file", [
      Alcotest.test_case "ok"        `Quick test_read_file;
      Alcotest.test_case "missing"   `Quick test_read_file_missing;
    ];
  ]
