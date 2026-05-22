open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

let err label input =
  match run input with
  | Error _ -> ()
  | Ok v -> Alcotest.failf "%s: expected error but got: %s" label v

(* ── Literals ────────────────────────────────────────────────────────────── *)

let test_literals () =
  ok "regex has type Regex"
    {|import Regex
let re = r/\d+/
Regex.match? re "abc123"|}
    "true";
  ok "regex literal inline"
    {|import String
String.match? r/hello/ "say hello"|}
    "true"

(* ── String.match? ───────────────────────────────────────────────────────── *)

let test_match () =
  ok "found"         {|import String; String.match? r/\d+/ "abc123"|}  "true";
  ok "not found"     {|import String; String.match? r/\d+/ "abc"|}     "false";
  ok "partial match" {|import String; String.match? r/b/ "abc"|}        "true";
  ok "anchored"      {|import String; String.match? r/^\d+$/ "123"|}   "true";
  ok "anchored fail" {|import String; String.match? r/^\d+$/ "1a"|}    "false"

(* ── Flags ───────────────────────────────────────────────────────────────── *)

let test_flags () =
  ok "case-insensitive i"
    {|import String; String.match? r/hello/i "HELLO"|}
    "true";
  ok "case-insensitive miss without flag"
    {|import String; String.match? r/hello/ "HELLO"|}
    "false";
  ok "multiline m — ^ matches line start"
    {|import String; String.match? r/^world/m "hello\nworld"|}
    "true";
  ok "dotall s — . matches newline"
    {|import String; String.match? r/a.b/s "a\nb"|}
    "true";
  ok "dotall off by default"
    {|import String; String.match? r/a.b/ "a\nb"|}
    "false"

(* ── String.capture ──────────────────────────────────────────────────────── *)

let test_capture () =
  ok "no match returns empty list"
    {|import String
import List
List.length (String.capture r/\d+/ "abc")|}
    "0";
  ok "full match at index 0"
    {|import String
import List
List.head (String.capture r/\d+/ "abc123")|}
    "123";
  ok "capture groups"
    {|import String
String.capture r/(\w+)@(\w+)/ "user@host"|}
    "[user@host, user, host]";
  ok "two groups"
    {|import String
String.capture r/^(\d+)-(\d+)$/ "2026-05"|}
    "[2026-05, 2026, 05]";
  ok "pattern match on result"
    {|import String
match String.capture r/^(\S+)\s+(\d+)/ "foo 42" with
| [] -> "no match"
| [_, name, num] -> "${name}:${num}"
| _ -> "other"|}
    "foo:42"

(* ── String.replace_re ───────────────────────────────────────────────────── *)

let test_replace () =
  ok "replace first match"
    {|import String; String.replace_re r/\d+/ "X" "a1b2c3"|}
    "aXb2c3";
  ok "no match returns original"
    {|import String; String.replace_re r/\d+/ "X" "abc"|}
    "abc"

(* ── String.replace_all_re ───────────────────────────────────────────────── *)

let test_replace_all () =
  ok "replace all matches"
    {|import String; String.replace_all_re r/\d+/ "X" "a1b2c3"|}
    "aXbXcX";
  ok "no match returns original"
    {|import String; String.replace_all_re r/\d+/ "X" "abc"|}
    "abc";
  ok "replace with empty string"
    {|import String; String.replace_all_re r/\s+/ "" "a b  c"|}
    "abc"

(* ── String.split_re ─────────────────────────────────────────────────────── *)

let test_split_re () =
  ok "split on whitespace"
    {|import String; String.split_re r/\s+/ "a  b   c"|}
    "[a, b, c]";
  ok "split on delimiter"
    {|import String; String.split_re r/,\s*/ "a, b,c"|}
    "[a, b, c]"

(* ── Regex module ────────────────────────────────────────────────────────── *)

let test_regex_module () =
  ok "Regex.match?"
    {|import Regex; Regex.match? r/\d+/ "abc123"|}
    "true";
  ok "Regex.capture"
    {|import Regex; Regex.capture r/(\d+)/ "abc123"|}
    "[123, 123]";
  ok "Regex.replace"
    {|import Regex; Regex.replace r/\d+/ "X" "a1b2"|}
    "aXb2";
  ok "Regex.replace_all"
    {|import Regex; Regex.replace_all r/\d+/ "X" "a1b2"|}
    "aXbX";
  ok "Regex.split"
    {|import Regex; Regex.split r/,/ "a,b,c"|}
    "[a, b, c]"

(* ── Regex.compile ───────────────────────────────────────────────────────── *)

let test_compile () =
  ok "compile valid pattern"
    {|import Regex
match Regex.compile "\\d+" with
| Ok re  -> Regex.match? re "abc123"
| Error _ -> false|}
    "true";
  ok "compile invalid pattern returns Error"
    {|import Regex
match Regex.compile "[invalid" with
| Ok _    -> "ok"
| Error _ -> "error"|}
    "error"

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Regex" [
    "literals", [
      Alcotest.test_case "regex literals" `Quick test_literals;
    ];
    "String.match?", [
      Alcotest.test_case "match"  `Quick test_match;
      Alcotest.test_case "flags"  `Quick test_flags;
    ];
    "String.capture", [
      Alcotest.test_case "capture" `Quick test_capture;
    ];
    "String.replace_re", [
      Alcotest.test_case "replace"     `Quick test_replace;
      Alcotest.test_case "replace_all" `Quick test_replace_all;
    ];
    "String.split_re", [
      Alcotest.test_case "split_re" `Quick test_split_re;
    ];
    "Regex module", [
      Alcotest.test_case "module functions" `Quick test_regex_module;
      Alcotest.test_case "compile"          `Quick test_compile;
    ];
  ]
