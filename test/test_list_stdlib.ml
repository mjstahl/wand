open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

let err label input =
  match run input with
  | Error _ -> ()
  | Ok v -> Alcotest.failf "%s: expected error but got: %s" label v

(* ── sort ────────────────────────────────────────────────────────────────────── *)

let test_sort () =
  ok "sort ints"
    {|import List
List.sort [3, 1, 2]|}
    "[1, 2, 3]";
  ok "sort strings"
    {|import List
List.sort ["banana", "apple", "cherry"]|}
    "[apple, banana, cherry]";
  ok "sort empty"
    {|import List
List.sort []|}
    "[]"

(* ── sort_by ─────────────────────────────────────────────────────────────────── *)

let test_sort_by () =
  ok "sort_by string length"
    {|import List
import String
List.sort_by String.length ["banana", "kiwi", "fig"]|}
    "[fig, kiwi, banana]";
  ok "sort_by negate (descending)"
    {|import List
List.sort_by (fn x -> 0 - x) [3, 1, 4, 1, 5]|}
    "[5, 4, 3, 1, 1]"

(* ── unique ──────────────────────────────────────────────────────────────────── *)

let test_unique () =
  ok "unique ints"
    {|import List
List.unique [1, 2, 1, 3, 2]|}
    "[1, 2, 3]";
  ok "unique preserves order"
    {|import List
List.unique ["c", "a", "b", "a", "c"]|}
    "[c, a, b]";
  ok "unique empty"
    {|import List
List.unique []|}
    "[]"

(* ── range ───────────────────────────────────────────────────────────────────── *)

let test_range () =
  ok "range basic"
    {|import List
List.range 1 5|}
    "[1, 2, 3, 4, 5]";
  ok "range single"
    {|import List
List.range 3 3|}
    "[3]";
  ok "range empty (hi < lo)"
    {|import List
List.range 5 1|}
    "[]"

(* ── flatten ─────────────────────────────────────────────────────────────────── *)

let test_flatten () =
  ok "flatten basic"
    {|import List
List.flatten [[1, 2], [3], [4, 5]]|}
    "[1, 2, 3, 4, 5]";
  ok "flatten empty lists"
    {|import List
List.flatten [[], [1], []]|}
    "[1]";
  ok "flatten empty"
    {|import List
List.flatten []|}
    "[]"

(* ── concat ──────────────────────────────────────────────────────────────────── *)

let test_concat () =
  ok "concat basic"
    {|import List
List.concat [1, 2] [3, 4]|}
    "[1, 2, 3, 4]";
  ok "concat with empty"
    {|import List
List.concat [] [1, 2]|}
    "[1, 2]";
  ok "concat both empty"
    {|import List
List.concat [] []|}
    "[]"

(* ── pipeline ────────────────────────────────────────────────────────────────── *)

let test_pipeline () =
  ok "range |> filter |> sort_by"
    {|import List
List.range 1 10
|> List.filter (fn x -> x % 2 == 0)
|> List.sort_by (fn x -> 0 - x)|}
    "[10, 8, 6, 4, 2]";
  ok "flatten after map"
    {|import List
List.range 1 3
|> List.map (fn x -> [x, x * 2])
|> List.flatten|}
    "[1, 2, 2, 4, 3, 6]"

(* ── get / get! ──────────────────────────────────────────────────────────── *)

let test_get () =
  ok "get 0"
    {|import List
match List.get 0 ["a", "b", "c"] with
| Ok v  -> v
| Error _ -> ""|}
    "a";
  ok "get 2"
    {|import List
match List.get 2 ["a", "b", "c"] with
| Ok v  -> v
| Error _ -> ""|}
    "c";
  ok "get out of bounds returns Error"
    {|import List
match List.get 5 ["a", "b"] with
| Ok _    -> "ok"
| Error _ -> "error"|}
    "error";
  ok "get negative returns Error"
    {|import List
match List.get (-1) ["a"] with
| Ok _    -> "ok"
| Error _ -> "error"|}
    "error"

let test_get_exn () =
  ok "get! 1"
    {|import List
List.get! 1 [10, 20, 30]|}
    "20";
  ok "get! works on nested lists"
    {|import List
List.get! 0 (List.get! 1 [[1, 2], [3, 4]])|}
    "3"

let err_get_exn () =
  let run s = Runner.run_string s in
  match run {|import List
List.get! 9 [1, 2, 3]|} with
  | Error _ -> ()
  | Ok v -> Alcotest.failf "get! OOB: expected error but got: %s" v

(* ── Suite ───────────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "List stdlib" [
    "core", [
      Alcotest.test_case "sort"     `Quick test_sort;
      Alcotest.test_case "sort_by"  `Quick test_sort_by;
      Alcotest.test_case "unique"   `Quick test_unique;
      Alcotest.test_case "range"    `Quick test_range;
      Alcotest.test_case "flatten"  `Quick test_flatten;
      Alcotest.test_case "concat"   `Quick test_concat;
      Alcotest.test_case "pipeline" `Quick test_pipeline;
    ];
    "get", [
      Alcotest.test_case "get"      `Quick test_get;
      Alcotest.test_case "get_exn"  `Quick test_get_exn;
      Alcotest.test_case "get_oob"  `Quick err_get_exn;
    ];
  ]
