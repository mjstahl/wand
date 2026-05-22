open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

let err label input =
  match run input with
  | Error _ -> ()
  | Ok v -> Alcotest.failf "%s: expected error but got: %s" label v

(* ── parse ───────────────────────────────────────────────────────────────── *)

let test_parse_basic () =
  ok "single row"
    {|import CSV
import List
let rows = CSV.parse "a,b,c"
List.length rows|}
    "1";
  ok "field value"
    {|import CSV
import List
let rows = CSV.parse "hello,world"
List.head (List.head rows)|}
    "hello";
  ok "multiple rows"
    {|import CSV
import List
let rows = CSV.parse "a,b\nc,d"
List.length rows|}
    "2";
  ok "field count per row"
    {|import CSV
import List
let rows = CSV.parse "a,b,c"
List.length (List.head rows)|}
    "3"

let test_parse_quoted () =
  ok "quoted field with space"
    {|import CSV
import List
let rows = CSV.parse "\"hello world\",b"
List.head (List.head rows)|}
    "hello world";
  ok "embedded comma"
    {|import CSV
import List
let rows = CSV.parse "\"a,b\",c"
List.head (List.head rows)|}
    "a,b";
  ok "escaped quote"
    {|import CSV
import List
let rows = CSV.parse "\"say \"\"hi\"\"\",b"
List.head (List.head rows)|}
    {|say "hi"|}

(* ── parse_with ──────────────────────────────────────────────────────────── *)

let test_parse_with () =
  ok "tab separator field count"
    {|import CSV
import List
let rows = CSV.parse_with "\t" "a\tb\tc"
List.length (List.head rows)|}
    "3";
  ok "pipe separator second field"
    {|import CSV
import List
let rows = CSV.parse_with "|" "x|y"
List.head (List.tail (List.head rows))|}
    "y"

(* ── stringify ───────────────────────────────────────────────────────────── *)

let test_stringify () =
  ok "simple two-row output"
    {|import CSV
CSV.stringify [["a", "b"], ["c", "d"]]|}
    "a,b\nc,d";
  ok "quotes field containing comma"
    {|import CSV
CSV.stringify [["a,b", "c"]]|}
    {|"a,b",c|};
  ok "stringify_with custom separator"
    {|import CSV
CSV.stringify_with "|" [["x", "y"]]|}
    "x|y"

(* ── read_file ───────────────────────────────────────────────────────────── *)

let with_csv content f =
  let path = Filename.temp_file "wand_csv_" ".csv" in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect f ~finally:(fun () -> Sys.remove path)

let test_read_file () =
  with_csv "name,age\nAlice,30\nBob,25\n" (fun () ->
    let path = Filename.temp_file "wand_csv_rd_" ".csv" in
    let oc = open_out path in
    output_string oc "name,age\nAlice,30\nBob,25\n";
    close_out oc;
    ok "row count via Ok"
      (Printf.sprintf {|import CSV
import List
import Path
match CSV.read_file (Path.of_string "%s") with
| Ok rows -> List.length rows
| Error _ -> -1|} path)
      "3";
    ok "header field"
      (Printf.sprintf {|import CSV
import List
import Path
match CSV.read_file (Path.of_string "%s") with
| Ok rows -> List.head (List.head rows)
| Error _ -> ""|} path)
      "name";
    Sys.remove path)

let test_read_file_missing () =
  ok "missing file gives Error"
    {|import CSV
import Path
match CSV.read_file (Path.of_string "/nonexistent/wand_missing.csv") with
| Ok _    -> "ok"
| Error _ -> "error"|}
    "error"

let test_read_file_exn () =
  with_csv "x,y\n1,2\n" (fun () ->
    let path = Filename.temp_file "wand_csv_exn_" ".csv" in
    let oc = open_out path in
    output_string oc "x,y\n1,2\n";
    close_out oc;
    ok "read_file! row count"
      (Printf.sprintf {|import CSV
import List
import Path
let rows = CSV.read_file! (Path.of_string "%s")
List.length rows|} path)
      "2";
    Sys.remove path);
  err "read_file! raises on missing"
    {|import CSV
import Path
CSV.read_file! (Path.of_string "/nonexistent/wand_missing.csv")|}

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "CSV module" [
    "parse", [
      Alcotest.test_case "basic"      `Quick test_parse_basic;
      Alcotest.test_case "quoted"     `Quick test_parse_quoted;
      Alcotest.test_case "parse_with" `Quick test_parse_with;
    ];
    "stringify", [
      Alcotest.test_case "basic"      `Quick test_stringify;
    ];
    "read_file", [
      Alcotest.test_case "ok"         `Quick test_read_file;
      Alcotest.test_case "missing"    `Quick test_read_file_missing;
      Alcotest.test_case "exn"        `Quick test_read_file_exn;
    ];
  ]
