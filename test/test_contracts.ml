open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

let err_contains label input needle =
  match run input with
  | Error msg ->
    if not (String.length msg >= String.length needle &&
            let hn = String.length msg and nn = String.length needle in
            let found = ref false in
            for i = 0 to hn - nn do
              if String.sub msg i nn = needle then found := true
            done; !found)
    then Alcotest.failf "%s: expected '%s' in error, got: %s" label needle msg
  | Ok s -> Alcotest.failf "%s: expected error but got: %s" label s

(* ── requires ────────────────────────────────────────────────────────────── *)

let test_requires () =
  ok "requires passes"
    "let abs x =\n  requires x >= 0\n  x\nabs 5"
    "5";
  err_contains "requires fails"
    "let abs x =\n  requires x >= 0\n  x\nabs (-1)"
    "precondition failed";
  err_contains "requires shows condition"
    "let abs x =\n  requires x >= 0\n  x\nabs (-1)"
    "x >= 0"

let test_multiple_requires () =
  ok "all requires pass"
    "let clamp lo hi x =\n  requires lo <= hi\n  requires x >= 0\n  if x < lo then lo else if x > hi then hi else x\nclamp 0 10 5"
    "5";
  err_contains "first requires fails"
    "let clamp lo hi x =\n  requires lo <= hi\n  requires x >= 0\n  if x < lo then lo else if x > hi then hi else x\nclamp 10 0 5"
    "precondition failed"

(* ── ensures ─────────────────────────────────────────────────────────────── *)

let test_ensures () =
  ok "ensures passes"
    "let abs x =\n  ensures result >= 0\n  if x < 0 then 0 - x else x\nabs (-5)"
    "5";
  err_contains "ensures fails"
    "let broken x =\n  ensures result > 100\n  x\nbroken 5"
    "postcondition failed";
  err_contains "ensures shows condition"
    "let broken x =\n  ensures result > 100\n  x\nbroken 5"
    "result > 100"

(* ── requires + ensures ─────────────────────────────────────────────────── *)

let test_both () =
  ok "clamp with contracts"
    {|let clamp lo hi x =
  requires lo <= hi
  ensures result >= lo
  ensures result <= hi
  if x < lo then lo else if x > hi then hi else x
clamp 0 10 15|}
    "10";
  ok "result equals expected"
    {|let double x =
  ensures result == x * 2
  x * 2
double 7|}
    "14"

(* ── type errors ─────────────────────────────────────────────────────────── *)

let test_type_errors () =
  err_contains "requires must be bool"
    "let f x =\n  requires x + 1\n  x\nf 1"
    "type error";
  err_contains "ensures must be bool"
    "let f x =\n  ensures result + 1\n  x\nf 1"
    "type error"

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Contracts" [
    "requires", [
      Alcotest.test_case "requires"          `Quick test_requires;
      Alcotest.test_case "multiple requires" `Quick test_multiple_requires;
    ];
    "ensures", [
      Alcotest.test_case "ensures"           `Quick test_ensures;
    ];
    "combined", [
      Alcotest.test_case "requires + ensures" `Quick test_both;
    ];
    "type errors", [
      Alcotest.test_case "contract types"    `Quick test_type_errors;
    ];
  ]
