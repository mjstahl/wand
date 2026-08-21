open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

let err_contains label input needle =
  let contains haystack needle =
    let hn = String.length haystack and nn = String.length needle in
    if nn = 0 then true
    else if nn > hn then false
    else begin
      let found = ref false in
      for i = 0 to hn - nn do
        if String.sub haystack i nn = needle then found := true
      done;
      !found
    end
  in
  match run input with
  | Error msg ->
    if not (contains msg needle) then
      Alcotest.failf "%s: expected '%s' in error, got: %s" label needle msg
  | Ok s -> Alcotest.failf "%s: expected error but got: %s" label s

(* ── Bool ─────────────────────────────────────────────────────────────────── *)

let test_bool () =
  ok "exhaustive bool"
    "let f b = match b with | true -> 1 | false -> 0; f true"
    "1";
  err_contains "missing false case" "let f b = match b with | true -> 1" "non-exhaustive"

(* ── Int / String: infinite domains need a wildcard ──────────────────────── *)

let test_infinite_domain () =
  ok "int with wildcard"
    {|let f x = match x with | 0 -> "zero" | _ -> "other"; f 5|}
    "other";
  err_contains "int without wildcard"
    {|let f x = match x with | 0 -> "zero"|}
    "non-exhaustive";
  err_contains "guard-only case doesn't count"
    {|let f x = match x with | n when n > 0 -> "pos" | _ -> "" ; let g y = match y with | n when n > 0 -> "pos"|}
    "non-exhaustive"

(* ── Tuples ───────────────────────────────────────────────────────────────── *)

let test_tuple () =
  ok "tuple wildcard-covered"
    "let f p = match p with | (a, b) -> a + b; f (1, 2)"
    "3"

(* ── Lists ────────────────────────────────────────────────────────────────── *)

let test_list () =
  ok "exhaustive list"
    "let f xs = match xs with | [] -> 0 | [h :: _] -> h; f [1, 2]"
    "1";
  err_contains "missing empty-list case"
    "let f xs = match xs with | [h :: _] -> h"
    "non-exhaustive"

(* ── Result ───────────────────────────────────────────────────────────────── *)

let test_result () =
  ok "exhaustive result"
    {|let f r = match r with | Ok v -> v | Error _ -> "err"; f (Ok "hi")|}
    "hi";
  err_contains "missing Error case"
    {|let f r = match r with | Ok v -> v|}
    "non-exhaustive"

(* ── User-defined ADTs (including generic) ───────────────────────────────── *)

let test_adt () =
  ok "exhaustive enum"
    "type Color = Red | Green | Blue
     let f c = match c with | Red -> 1 | Green -> 2 | Blue -> 3
     f Red"
    "1";
  err_contains "missing enum case"
    "type Color = Red | Green | Blue
     let f c = match c with | Red -> 1 | Green -> 2"
    "non-exhaustive";
  ok "exhaustive generic option"
    "type Option 'a = None | Some 'a
     let f o = match o with | Some v -> v | None -> 0
     f (Some 5)"
    "5";
  err_contains "missing None case"
    "type Option 'a = None | Some 'a
     let f o = match o with | Some v -> v"
    "non-exhaustive";
  err_contains "missing nested case inside covered outer constructor"
    "type Shape = Circle Int | Rect Int Int
     type Wrapped = Wrap Shape
     let f w = match w with
       | Wrap (Circle _) -> 1"
    "non-exhaustive"

(* ── Map: excluded, always satisfied ─────────────────────────────────────── *)

let test_map () =
  ok "map pattern never flagged"
    {|import Map
      let m = Map.from_list [("a", 1)]
      match m with | {a = x} -> x|}
    "1"

(* ── Suite ────────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Exhaustiveness" [
    "bool", [ Alcotest.test_case "bool" `Quick test_bool ];
    "infinite domain", [ Alcotest.test_case "infinite domain" `Quick test_infinite_domain ];
    "tuple", [ Alcotest.test_case "tuple" `Quick test_tuple ];
    "list", [ Alcotest.test_case "list" `Quick test_list ];
    "result", [ Alcotest.test_case "result" `Quick test_result ];
    "adt", [ Alcotest.test_case "adt" `Quick test_adt ];
    "map", [ Alcotest.test_case "map" `Quick test_map ];
  ]
