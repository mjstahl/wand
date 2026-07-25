open Wand

let fmt s = Formatter.format_source s

(* ── Idempotency ──────────────────────────────────────────────────────────── *)

let assert_idempotent label src =
  let once = fmt src in
  let twice = fmt once in
  Alcotest.(check string) label once twice

let test_idempotent_stdlib () =
  let dir = "../../../stdlib" in
  if Sys.file_exists dir then
    Array.iter (fun name ->
      if Filename.check_suffix name ".wand" then
        let path = Filename.concat dir name in
        let src = In_channel.with_open_text path In_channel.input_all in
        assert_idempotent name src
    ) (Sys.readdir dir)

let test_idempotent_snippets () =
  assert_idempotent "let binding" "let x = 1\nx + 1";
  assert_idempotent "if/else" "let f x = if x > 0 then \"pos\" else \"neg\"";
  assert_idempotent "match" "let f x = match x with\n| 0 -> \"zero\"\n| _ -> \"other\""

(* ── Behavior preservation ───────────────────────────────────────────────── *)

let ok_after_format label src expected =
  let formatted = fmt src in
  match Runner.run_string formatted with
  | Ok v -> Alcotest.(check string) label expected v
  | Error msg -> Alcotest.failf "%s: formatted code failed to run: %s\nformatted:\n%s" label msg formatted

let test_behavior_preserved () =
  ok_after_format "arithmetic" "1 + 2 * 3" "7";
  ok_after_format "multi-equation function"
    "let fact 0 = 1\nlet fact n = n * fact (n - 1)\nfact 5"
    "120";
  ok_after_format "nested app needs parens"
    "let add a b = a + b\nlet f g x = g (add x 1) 2\nf add 3"
    "6";
  ok_after_format "match with guard"
    {|let f x = match x with
| n when n < 0 -> "neg"
| 0 -> "zero"
| _ -> "pos"
f (-5)|}
    "neg";
  ok_after_format "tuple destructure"
    "let (a, b) = (1, 2)\na + b"
    "3";
  ok_after_format "cons pattern"
    "let f [h : t] = h\nf [1, 2, 3]"
    "1"

(* ── Comment preservation ────────────────────────────────────────────────── *)

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

let assert_contains label out needle =
  if not (contains out needle) then
    Alcotest.failf "%s: expected to find %S in output:\n%s" label needle out

let test_comments_preserved () =
  let src = "(* a leading comment *)\nlet x = 1\nx + 1" in
  assert_contains "leading comment" (fmt src) "a leading comment";
  let src2 = "let x = 1 (* trailing note *)\nlet y = 2\nx + y" in
  assert_contains "same-line comment" (fmt src2) "trailing note";
  let src3 = "(** a doc comment *)\nlet x = 1\nx" in
  assert_contains "doc comment" (fmt src3) "a doc comment"

let test_blank_lines () =
  let src = "let x = 1\n\n\n\nlet y = 2\nx + y" in
  let out = fmt src in
  (* collapse to at most one blank line between items *)
  if contains out "\n\n\n" then
    Alcotest.failf "expected blank-line run to collapse to one, got:\n%s" out

(* ── Suite ────────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Formatter" [
    "idempotency", [
      Alcotest.test_case "snippets" `Quick test_idempotent_snippets;
      Alcotest.test_case "stdlib"   `Quick test_idempotent_stdlib;
    ];
    "behavior preserved", [
      Alcotest.test_case "behavior" `Quick test_behavior_preserved;
    ];
    "comments", [
      Alcotest.test_case "preserved"  `Quick test_comments_preserved;
      Alcotest.test_case "blank lines" `Quick test_blank_lines;
    ];
  ]
