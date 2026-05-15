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
  ]
