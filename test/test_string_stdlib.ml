open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

let err label input =
  match run input with
  | Error _ -> ()
  | Ok s -> Alcotest.failf "%s: expected error but got: %s" label s

(* ── length ─────────────────────────────────────────────────────────────── *)

let test_length () =
  ok "empty"    {|import String
start String.length ""|} "0";
  ok "hello"    {|import String
start String.length "hello"|} "5";
  ok "unicode"  {|import String
start String.length "abc"|} "3"

(* ── upper / lower ──────────────────────────────────────────────────────── *)

let test_case () =
  ok "upper" {|import String
start String.upper "hello"|} "HELLO";
  ok "lower" {|import String
start String.lower "WORLD"|} "world";
  ok "round trip" {|import String
start String.lower (String.upper "Hello")|} "hello"

(* ── trim ───────────────────────────────────────────────────────────────── *)

let test_trim () =
  ok "spaces"   {|import String
start String.trim "  hello  "|} "hello";
  ok "newlines" {|import String
start String.trim "\n  hi\n"|} "hi";
  ok "clean"    {|import String
start String.trim "clean"|} "clean"

(* ── slice ──────────────────────────────────────────────────────────────── *)

let test_slice () =
  ok "full"    {|import String
start String.slice 0 5 "hello"|} "hello";
  ok "prefix"  {|import String
start String.slice 0 3 "hello"|} "hel";
  ok "suffix"  {|import String
start String.slice 2 5 "hello"|} "llo";
  ok "empty"   {|import String
start String.slice 2 2 "hello"|} "";
  ok "clamp"   {|import String
start String.slice 0 100 "hi"|} "hi"

(* ── split ──────────────────────────────────────────────────────────────── *)

let test_split () =
  ok "csv"     {|import String
start String.split "," "a,b,c"|} "[a, b, c]";
  ok "no match" {|import String
start String.split "," "abc"|} "[abc]";
  ok "words"   {|import String
start String.split " " "hello world"|} "[hello, world]"

(* ── contains / starts_with / ends_with ─────────────────────────────────── *)

let test_predicates () =
  ok "contains yes"    {|import String
start String.contains "ll" "hello"|} "true";
  ok "contains no"     {|import String
start String.contains "xy" "hello"|} "false";
  ok "starts_with yes" {|import String
start String.starts_with "he" "hello"|} "true";
  ok "starts_with no"  {|import String
start String.starts_with "lo" "hello"|} "false";
  ok "ends_with yes"   {|import String
start String.ends_with "lo" "hello"|} "true";
  ok "ends_with no"    {|import String
start String.ends_with "he" "hello"|} "false"

(* ── replace ────────────────────────────────────────────────────────────── *)

let test_replace () =
  ok "basic"    {|import String
start String.replace "o" "0" "hello world"|} "hell0 w0rld";
  ok "no match" {|import String
start String.replace "x" "y" "hello"|} "hello";
  ok "prefix"   {|import String
start String.replace "he" "HE" "hello"|} "HEllo"

(* ── chars ──────────────────────────────────────────────────────────────── *)

let test_chars () =
  ok "chars" {|import String
start String.chars "abc"|} "[a, b, c]";
  ok "empty" {|import String
start String.chars ""|} "[]"

(* ── of_int / to_int ────────────────────────────────────────────────────── *)

let test_conversions () =
  ok "of_int"   {|import String
start String.of_int 42|} "42";
  ok "to_int"   {|import String
start String.to_int "123"|} "123";
  ok "negative" {|import String
start String.of_int (-7)|} "-7";
  err "bad int" {|import String
start String.to_int "abc"|}

(* ── join ───────────────────────────────────────────────────────────────── *)

let test_join () =
  ok "csv"    {|import String
start String.join ", " ["a", "b", "c"]|} "a, b, c";
  ok "empty"  {|import String
start String.join ", " []|} "";
  ok "single" {|import String
start String.join ", " ["only"]|} "only"

(* ── lines / words ──────────────────────────────────────────────────────── *)

let test_lines_words () =
  ok "lines" {|import String
start String.lines "a\nb\nc"|} "[a, b, c]";
  ok "words" {|import String
start String.words "one two three"|} "[one, two, three]"

(* ── pipeline style ─────────────────────────────────────────────────────── *)

let test_pipeline () =
  ok "pipe" {|import String
let s = "  Hello, World!  "
start s |> String.trim |> String.lower|} "hello, world!"

(* ── Suite ──────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "String stdlib" [
    "core", [
      Alcotest.test_case "length"      `Quick test_length;
      Alcotest.test_case "case"        `Quick test_case;
      Alcotest.test_case "trim"        `Quick test_trim;
      Alcotest.test_case "slice"       `Quick test_slice;
      Alcotest.test_case "split"       `Quick test_split;
      Alcotest.test_case "predicates"  `Quick test_predicates;
      Alcotest.test_case "replace"     `Quick test_replace;
      Alcotest.test_case "chars"       `Quick test_chars;
      Alcotest.test_case "conversions" `Quick test_conversions;
      Alcotest.test_case "join"        `Quick test_join;
      Alcotest.test_case "lines/words" `Quick test_lines_words;
      Alcotest.test_case "pipeline"    `Quick test_pipeline;
    ];
  ]
