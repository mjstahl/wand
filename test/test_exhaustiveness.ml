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
  (* Declared here rather than reaching for `Option`, which is built in and
     so cannot be declared. The shape is what is under test. *)
  ok "exhaustive generic variant"
    "type Maybe 'a = Nothing | Just 'a
     let f o = match o with | Just v -> v | Nothing -> 0
     f (Just 5)"
    "5";
  err_contains "missing empty case"
    "type Maybe 'a = Nothing | Just 'a
     let f o = match o with | Just v -> v"
    "non-exhaustive";
  (* The built-in one is checked the same way, with nothing declared and
     nothing imported. *)
  ok "exhaustive Option"
    "let f o = match o with | Some v -> v | None -> 0
let x = f (Some 5)
x"
    "5";
  err_contains "missing None case"
    "let f o = match o with | Some v -> v
let x = f (Some 5)
x"
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

(* ── The witness must be a pattern you can paste back in ─────────────────── *)

(* The counterexample used to print cons as `h : t`, the transitional
   spelling removed in 0.31.0, and without the brackets a list pattern is
   written with. Copying it into the source gave "cons is '::'" -- one error
   telling you to write what the other rejects. So the test is not what the
   message says, it is that following it works. *)

let witness_of msg =
  let marker = "e.g. " in
  let ml = String.length marker and n = String.length msg in
  let rec find i =
    if i + ml > n then None
    else if String.sub msg i ml = marker then Some (String.sub msg (i + ml) (n - i - ml))
    else find (i + 1)
  in
  find 0

let copyable label ~before ~after =
  match run before with
  | Ok s -> Alcotest.failf "%s: expected a non-exhaustive error, got: %s" label s
  | Error msg ->
    match witness_of msg with
    | None -> Alcotest.failf "%s: no 'e.g.' witness in: %s" label msg
    | Some w ->
      (* Splice the witness in as a new case and the match must close. *)
      let patched = Printf.sprintf after w in
      (match run patched with
       | Ok _ -> ()
       | Error m2 ->
         Alcotest.failf "%s: the suggested case '%s' does not work: %s" label w m2)

let test_witness_copyable () =
  copyable "one-element list gap"
    ~before:"let f xs = match xs with | [] -> 0 | [a :: [b :: _]] -> a + b"
    ~after:"let f xs = match xs with | [] -> 0 | %s -> 1 | [a :: [b :: _]] -> a + b; f [1]";
  copyable "cons inside a constructor"
    ~before:"let f o = match o with | None -> 0 | Some [] -> 0 | Some [a :: [b :: _]] -> a"
    ~after:"let f o = match o with | None -> 0 | Some [] -> 0 | %s -> 1 | Some [a :: [b :: _]] -> a; f None";
  copyable "tuple gap"
    ~before:"let f p = match p with | (1, y) -> y"
    ~after:"let f p = match p with | (1, y) -> y | %s -> 0; f (1, 2)";
  err_contains "cons renders with :: and brackets"
    "let f xs = match xs with | [] -> 0 | [a :: [b :: _]] -> a + b"
    "[_ :: []]"

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
    "witness", [ Alcotest.test_case "witness is copyable" `Quick test_witness_copyable ];
  ]
