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
  ok "null"
    {|import JSON
match JSON.parse "null" with
| Ok j  -> JSON.stringify j
| Error _ -> "err"|}
    "null";
  ok "number"
    {|import JSON
match JSON.parse "42" with
| Ok j  -> JSON.stringify j
| Error _ -> "err"|}
    "42";
  ok "string"
    {|import JSON
match JSON.parse "\"hello\"" with
| Ok j  -> JSON.stringify j
| Error _ -> "err"|}
    {|"hello"|};
  ok "bad JSON returns Error"
    {|import JSON
match JSON.parse "{bad}" with
| Ok _    -> "ok"
| Error _ -> "error"|}
    "error"

let test_parse_exn () =
  ok "parse! valid"
    {|import JSON
JSON.stringify (JSON.parse! "true")|}
    "true";
  err "parse! invalid raises"
    {|import JSON
JSON.parse! "not json"|}

(* ── get_* extractors ────────────────────────────────────────────────────── *)

let test_get_bool () =
  ok "get_bool true"
    {|import JSON
match JSON.get_bool (JSON.parse! "true") with
| Ok b  -> b
| Error _ -> false|}
    "true";
  ok "get_bool wrong type"
    {|import JSON
match JSON.get_bool (JSON.parse! "42") with
| Ok _    -> "ok"
| Error _ -> "error"|}
    "error"

let test_get_int () =
  ok "get_int"
    {|import JSON
match JSON.get_int (JSON.parse! "99") with
| Ok n  -> n
| Error _ -> -1|}
    "99";
  ok "get_int wrong type"
    {|import JSON
match JSON.get_int (JSON.parse! "\"hi\"") with
| Ok _    -> "ok"
| Error _ -> "error"|}
    "error"

let test_get_float () =
  ok "get_float from float literal"
    {|import JSON
match JSON.get_float (JSON.parse! "3.14") with
| Ok f  -> f > 3.0
| Error _ -> false|}
    "true";
  ok "get_float from int literal"
    {|import JSON
match JSON.get_float (JSON.parse! "2") with
| Ok f  -> f == 2.0
| Error _ -> false|}
    "true"

let test_get_string () =
  ok "get_string"
    {|import JSON
match JSON.get_string (JSON.parse! "\"world\"") with
| Ok s  -> s
| Error _ -> ""|}
    "world"

let test_get_array () =
  ok "get_array length"
    {|import JSON
import List
match JSON.get_array (JSON.parse! "[1,2,3]") with
| Ok xs -> List.length xs
| Error _ -> -1|}
    "3"

let test_get_object () =
  ok "get_object then field"
    {|import JSON
import Map
match JSON.get_object (JSON.parse! "{\"k\":\"v\"}") with
| Ok m  -> JSON.stringify (Map.get! "k" m)
| Error _ -> ""|}
    {|"v"|}

(* ── field / field! ──────────────────────────────────────────────────────── *)

let test_field () =
  ok "field exists"
    {|import JSON
let j = JSON.parse! "{\"name\":\"Alice\",\"age\":30}"
match JSON.field "name" j with
| Ok v  -> JSON.stringify v
| Error _ -> ""|}
    {|"Alice"|};
  ok "field missing"
    {|import JSON
let j = JSON.parse! "{\"a\":1}"
match JSON.field "z" j with
| Ok _    -> "ok"
| Error _ -> "error"|}
    "error";
  ok "field! exists"
    {|import JSON
let j = JSON.parse! "{\"x\":42}"
JSON.stringify (JSON.field! "x" j)|}
    "42";
  err "field! missing raises"
    {|import JSON
let j = JSON.parse! "{\"a\":1}"
JSON.field! "z" j|}

(* ── construction ─────────────────────────────────────────────────────────── *)

let test_construction () =
  ok "of_bool"
    {|import JSON
JSON.stringify (JSON.of_bool true)|}
    "true";
  ok "of_int"
    {|import JSON
JSON.stringify (JSON.of_int 7)|}
    "7";
  ok "of_float"
    {|import JSON
JSON.stringify (JSON.of_float 1.5)|}
    "1.5";
  ok "of_string"
    {|import JSON
JSON.stringify (JSON.of_string "hi")|}
    {|"hi"|};
  ok "of_list"
    {|import JSON
JSON.stringify (JSON.of_list [JSON.of_int 1, JSON.of_int 2])|}
    "[1,2]";
  ok "null and is_null"
    {|import JSON
JSON.is_null JSON.null|}
    "true"

(* ── stringify_pretty ────────────────────────────────────────────────────── *)

let test_stringify_pretty () =
  ok "pretty round-trips"
    {|import JSON
let j = JSON.parse! "{\"a\":1}"
let s = JSON.stringify_pretty j
match JSON.parse s with
| Ok _    -> "ok"
| Error _ -> "error"|}
    "ok"

(* ── read_file ───────────────────────────────────────────────────────────── *)

let with_json_file content f =
  let path = Filename.temp_file "wand_json_" ".json" in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect f ~finally:(fun () -> Sys.remove path)

let test_read_file () =
  with_json_file {|{"greeting":"hello"}|} (fun () ->
    let path = Filename.temp_file "wand_json_rd_" ".json" in
    let oc = open_out path in
    output_string oc {|{"greeting":"hello"}|};
    close_out oc;
    ok "read_file ok"
      (Printf.sprintf {|import JSON
import Path
match JSON.read_file (Path.of_string "%s") with
| Ok j  -> JSON.stringify (JSON.field! "greeting" j)
| Error _ -> ""|}  path)
      {|"hello"|};
    Sys.remove path)

let test_read_file_missing () =
  ok "missing file returns Error"
    {|import JSON
import Path
match JSON.read_file (Path.of_string "/nonexistent/wand_missing.json") with
| Ok _    -> "ok"
| Error _ -> "error"|}
    "error"

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "JSON module" [
    "parse", [
      Alcotest.test_case "parse"     `Quick test_parse;
      Alcotest.test_case "parse_exn" `Quick test_parse_exn;
    ];
    "get", [
      Alcotest.test_case "bool"   `Quick test_get_bool;
      Alcotest.test_case "int"    `Quick test_get_int;
      Alcotest.test_case "float"  `Quick test_get_float;
      Alcotest.test_case "string" `Quick test_get_string;
      Alcotest.test_case "array"  `Quick test_get_array;
      Alcotest.test_case "object" `Quick test_get_object;
    ];
    "field", [
      Alcotest.test_case "field"  `Quick test_field;
    ];
    "construct", [
      Alcotest.test_case "of_*"   `Quick test_construction;
    ];
    "stringify", [
      Alcotest.test_case "pretty" `Quick test_stringify_pretty;
    ];
    "read_file", [
      Alcotest.test_case "ok"      `Quick test_read_file;
      Alcotest.test_case "missing" `Quick test_read_file_missing;
    ];
  ]
