open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

let err label input =
  match run input with
  | Error _ -> ()
  | Ok v -> Alcotest.failf "%s: expected error but got: %s" label v

(* ── Cons operator (expressions) ─────────────────────────────────────────── *)

let test_cons_expr () =
  ok "prepend one"    {|1 :: [2, 3]|}         "[1, 2, 3]";
  ok "chain cons"     {|1 :: 2 :: 3 :: []|}   "[1, 2, 3]";
  ok "cons onto empty" {|42 :: []|}            "[42]";
  ok "string cons"    {|"a" :: ["b", "c"]|}   "[a, b, c]"

(* ── List patterns ───────────────────────────────────────────────────────── *)

let test_empty_pattern () =
  ok "match empty"
    {|match [] with | [] -> "empty" | _ -> "non-empty"|}
    "empty";
  ok "match non-empty"
    {|match [1] with | [] -> "empty" | _ -> "non-empty"|}
    "non-empty"

let test_exact_pattern () =
  ok "exact one element"
    {|match [42] with | [x] -> x | _ -> 0|}
    "42";
  ok "exact two elements"
    {|match [3, 4] with | [x, y] -> x + y | _ -> 0|}
    "7"

let test_cons_pattern () =
  ok "head"
    {|match [1, 2, 3] with | [h :: _] -> h | [] -> 0|}
    "1";
  ok "tail"
    {|match [1, 2, 3] with | [_ :: t] -> t | [] -> []|}
    "[2, 3]";
  ok "no match on empty"
    {|match [] with | [_ :: _] -> "yes" | [] -> "no"|}
    "no"

(* ── Recursive functions over lists ──────────────────────────────────────── *)

let test_length () =
  ok "length"
    {|let len []       = 0
let len [_ :: t] = 1 + len t
len [1, 2, 3, 4, 5]|}
    "5";
  ok "length empty"
    {|let len []       = 0
let len [_ :: t] = 1 + len t
len []|}
    "0"

let test_sum () =
  ok "sum"
    {|let sum []       = 0
let sum [h :: t] = h + sum t
sum [1, 2, 3, 4, 5]|}
    "15"

let test_map () =
  ok "double"
    {|let map _ []       = []
let map f [h :: t] = f h :: map f t
map (fn x -> x * 2) [1, 2, 3]|}
    "[2, 4, 6]";
  ok "to string"
    {|let map _ []       = []
let map f [h :: t] = f h :: map f t
map (fn x -> x ++ "!") ["a", "b", "c"]|}
    "[a!, b!, c!]"

let test_filter () =
  ok "filter gt 2"
    {|let filter _ []       = []
let filter p [h :: t] =
  if p h then h :: filter p t
  else filter p t
filter (fn x -> x > 2) [1, 2, 3, 4, 5]|}
    "[3, 4, 5]"

let test_append () =
  ok "append"
    {|let append []       ys = ys
let append [h :: t] ys = h :: append t ys
append [1, 2] [3, 4]|}
    "[1, 2, 3, 4]"

let test_reverse () =
  ok "reverse"
    {|let rev_acc []       acc = acc
let rev_acc [h :: t] acc = rev_acc t (h :: acc)
let reverse xs = rev_acc xs []
reverse [1, 2, 3, 4, 5]|}
    "[5, 4, 3, 2, 1]"

(* ── Type errors ─────────────────────────────────────────────────────────── *)

let test_type_errors () =
  err "cons non-list rhs"    {|1 :: 2|};
  err "cons type mismatch"   {|1 :: ["a", "b"]|}

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "List patterns" [
    "cons", [
      Alcotest.test_case "cons expr"     `Quick test_cons_expr;
    ];
    "patterns", [
      Alcotest.test_case "empty"         `Quick test_empty_pattern;
      Alcotest.test_case "exact"         `Quick test_exact_pattern;
      Alcotest.test_case "cons"          `Quick test_cons_pattern;
    ];
    "recursive", [
      Alcotest.test_case "length"        `Quick test_length;
      Alcotest.test_case "sum"           `Quick test_sum;
      Alcotest.test_case "map"           `Quick test_map;
      Alcotest.test_case "filter"        `Quick test_filter;
      Alcotest.test_case "append"        `Quick test_append;
      Alcotest.test_case "reverse"       `Quick test_reverse;
    ];
    "types", [
      Alcotest.test_case "type errors"   `Quick test_type_errors;
    ];
  ]
