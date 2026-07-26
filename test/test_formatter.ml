open Wand

let fmt s = Formatter.format_source s

(* ── Idempotency ──────────────────────────────────────────────────────────── *)

let assert_idempotent label src =
  let once = fmt src in
  let twice = fmt once in
  Alcotest.(check string) label once twice

let test_idempotent_stdlib () =
  let dir = "../stdlib" in
  if not (Sys.file_exists dir) then
    Alcotest.failf "stdlib not found at %s (relative to test sandbox)" dir
  else
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
    "1";
  (* A match nested (unparenthesized in source) inside an outer match's
     case body: match arms only terminate at a non-`|` token, so an
     unparenthesized nested match here would swallow the outer match's
     remaining `| ...` arms into itself, changing the program's meaning. *)
  ok_after_format "match nested in match case body"
    {|let f x =
  match x with
  | Ok xs ->
    (match xs with
     | 1 -> "one"
     | _ -> "many")
  | Error _ -> "err"
f (Ok 1)|}
    "one";
  (* A recursive shorthand `let` (`let f n = ... f ... in ...`) is only
     recursive because of its exact surface syntax (see typechecker.ml's
     `Let (PVar name, Fn _, _)` special case) -- reformatting it as
     `let f = fn n -> ...` would drop that and break recursion. This is a
     regression guard for exactly that bug. *)
  ok_after_format "recursive local let stays recursive after formatting"
    "let f = fn t -> let fact n = if n <= 0 then 1 else n * fact (n - 1) in fact t\nf 5"
    "120"

(* `Ok 42.0` reformatting to `Ok 42` runs fine and *displays* the same (both
   show as "42"), so a `ok_after_format`-style behavior check can't catch it --
   only re-typechecking the formatted source tells Float and Int apart. *)
let type_after_format label src expected =
  let formatted = fmt src in
  let ty =
    Lexer.tokenize formatted
    |> Parser.parse_expr
    |> Typechecker.infer_expr
    |> Result.map Typechecker.string_of_typ
  in
  match ty with
  | Ok t    -> Alcotest.(check string) label expected t
  | Error e -> Alcotest.failf "%s: formatted code failed to typecheck: %s\nformatted:\n%s" label e formatted

let test_float_literal_type_preserved () =
  type_after_format "integral float keeps its type" "42.0" "Float";
  type_after_format "integral float in a constructor" "Ok 42.0" "Result 'a Float";
  type_after_format "non-integral float unaffected" "3.14" "Float"

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

(* A comment inside an item's own span (between multi-equation clauses,
   or inside a function body) must stay where it was, not get silently
   relocated to after the whole item -- verified by checking the comment
   still precedes the text that followed it in the original source. *)
let assert_appears_before label out needle_before needle_after =
  let find s =
    let n = String.length out and m = String.length s in
    let pos = ref (-1) in
    (try
       for i = 0 to n - m do
         if String.sub out i m = s then (pos := i; raise Exit)
       done
     with Exit -> ());
    !pos
  in
  let before_pos = find needle_before and after_pos = find needle_after in
  if before_pos < 0 then Alcotest.failf "%s: %S not found in output:\n%s" label needle_before out;
  if after_pos < 0 then Alcotest.failf "%s: %S not found in output:\n%s" label needle_after out;
  if not (before_pos < after_pos) then
    Alcotest.failf "%s: expected %S before %S, got:\n%s" label needle_before needle_after out

let test_interior_comment_position () =
  let src = "let f 0 = \"zero\"\n(* second clause *)\nlet f n = \"other\"\nf 3" in
  let out = fmt src in
  assert_contains "comment between multi-equation clauses" out "second clause";
  assert_appears_before "comment stays between clauses, not after both"
    out "second clause" "let f n";
  let src2 = "let f x =\n  (* explain this *)\n  x + 1\nf 5" in
  let out2 = fmt src2 in
  assert_contains "comment inside function body" out2 "explain this";
  assert_appears_before "comment stays inside body, not after the function"
    out2 "explain this" "f 5"

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
      Alcotest.test_case "float literal type" `Quick test_float_literal_type_preserved;
    ];
    "comments", [
      Alcotest.test_case "preserved"  `Quick test_comments_preserved;
      Alcotest.test_case "interior position" `Quick test_interior_comment_position;
      Alcotest.test_case "blank lines" `Quick test_blank_lines;
    ];
  ]
