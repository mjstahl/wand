open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

let err label input =
  match run input with
  | Error _ -> ()
  | Ok s -> Alcotest.failf "%s: expected error but got: %s" label s

(* ── length / is_empty? ─────────────────────────────────────────────────── *)

let test_length () =
  ok "empty"    {|import String
String.length ""|} "0";
  ok "hello"    {|import String
String.length "hello"|} "5";
  ok "is_empty? true"  {|import String
String.is_empty? ""|} "true";
  ok "is_empty? false" {|import String
String.is_empty? "x"|} "false"

(* ── upper / lower ──────────────────────────────────────────────────────── *)

let test_case () =
  ok "upper" {|import String
String.upper "hello"|} "HELLO";
  ok "lower" {|import String
String.lower "WORLD"|} "world";
  ok "round trip" {|import String
String.lower (String.upper "Hello")|} "hello"

(* ── trim ───────────────────────────────────────────────────────────────── *)

let test_trim () =
  ok "trim spaces"   {|import String
String.trim "  hello  "|} "hello";
  ok "trim newlines" {|import String
String.trim "\n  hi\n"|} "hi";
  ok "trim clean"    {|import String
String.trim "clean"|} "clean";
  ok "trim_left"     {|import String
String.trim_left "  hi  "|} "hi  ";
  ok "trim_right"    {|import String
String.trim_right "  hi  "|} "  hi"

(* ── slice ──────────────────────────────────────────────────────────────── *)

let test_slice () =
  ok "full"    {|import String
String.slice 0 5 "hello"|} "hello";
  ok "prefix"  {|import String
String.slice 0 3 "hello"|} "hel";
  ok "suffix"  {|import String
String.slice 2 5 "hello"|} "llo";
  ok "empty"   {|import String
String.slice 2 2 "hello"|} "";
  ok "clamp"   {|import String
String.slice 0 100 "hi"|} "hi"

(* ── split ──────────────────────────────────────────────────────────────── *)

let test_split () =
  ok "csv"     {|import String
String.split "," "a,b,c"|} "[a, b, c]";
  ok "no match" {|import String
String.split "," "abc"|} "[abc]";
  ok "words"   {|import String
String.split " " "hello world"|} "[hello, world]"

(* ── contains? / starts_with? / ends_with? ──────────────────────────────── *)

let test_predicates () =
  ok "contains? yes"      {|import String
String.contains? "ll" "hello"|} "true";
  ok "contains? no"       {|import String
String.contains? "xy" "hello"|} "false";
  ok "starts_with? yes"   {|import String
String.starts_with? "he" "hello"|} "true";
  ok "starts_with? no"    {|import String
String.starts_with? "lo" "hello"|} "false";
  ok "ends_with? yes"     {|import String
String.ends_with? "lo" "hello"|} "true";
  ok "ends_with? no"      {|import String
String.ends_with? "he" "hello"|} "false"

(* ── replace ────────────────────────────────────────────────────────────── *)

let test_replace () =
  ok "basic"    {|import String
String.replace "o" "0" "hello world"|} "hell0 w0rld";
  ok "no match" {|import String
String.replace "x" "y" "hello"|} "hello";
  ok "prefix"   {|import String
String.replace "he" "HE" "hello"|} "HEllo"

(* ── repeat / reverse ───────────────────────────────────────────────────── *)

let test_repeat_reverse () =
  ok "repeat 3"  {|import String
String.repeat 3 "ab"|} "ababab";
  ok "repeat 0"  {|import String
String.repeat 0 "ab"|} "";
  ok "repeat 1"  {|import String
String.repeat 1 "x"|} "x";
  ok "reverse"   {|import String
String.reverse "hello"|} "olleh";
  ok "reverse empty" {|import String
String.reverse ""|} ""

(* ── chars ──────────────────────────────────────────────────────────────── *)

let test_chars () =
  ok "chars" {|import String
String.chars "abc"|} "[a, b, c]";
  ok "empty" {|import String
String.chars ""|} "[]"

(* ── of_int / to_int / to_float ─────────────────────────────────────────── *)

let test_conversions () =
  ok "of_int"    {|import String
String.of_int 42|} "42";
  ok "to_int ok"    {|import String
String.to_int "123"|} "Ok(123)";
  ok "negative"  {|import String
String.of_int (-7)|} "-7";
  ok "to_float ok"  {|import String
String.to_float "3.14"|} "Ok(3.14)";
  ok "to_float int-like" {|import String
String.to_float "42"|} "Ok(42)";
  ok "to_int err"   {|import String
match String.to_int "abc" with
| Ok n -> "got int"
| Error _ -> "error"|} "error";
  ok "to_float err" {|import String
match String.to_float "abc" with
| Ok f -> "got float"
| Error _ -> "error"|} "error"

(* ── join ───────────────────────────────────────────────────────────────── *)

let test_join () =
  ok "csv"    {|import String
String.join ", " ["a", "b", "c"]|} "a, b, c";
  ok "empty"  {|import String
String.join ", " []|} "";
  ok "single" {|import String
String.join ", " ["only"]|} "only"

(* ── lines / words ──────────────────────────────────────────────────────── *)

let test_lines_words () =
  ok "lines" {|import String
String.lines "a\nb\nc"|} "[a, b, c]";
  ok "words" {|import String
String.words "one two three"|} "[one, two, three]"

(* ── pipeline ────────────────────────────────────────────────────────────── *)

let test_pipeline () =
  ok "pipe" {|import String
let s = "  Hello, World!  "
s |> String.trim |> String.lower|} "hello, world!"

(* ── to_bool / to_path ──────────────────────────────────────────────────── *)

let test_to_bool_path () =
  ok "to_bool true"  {|import String
String.to_bool "true"|} "Ok(true)";
  ok "to_bool false" {|import String
String.to_bool "False"|} "Ok(false)";
  ok "to_bool err"   {|import String
match String.to_bool "yes" with
| Ok b -> "got bool"
| Error _ -> "error"|} "error";
  ok "to_path"       {|import String
match String.to_path "/tmp/foo" with
| p -> "got path"|} "got path"

(* ── domain type parsers ────────────────────────────────────────────────── *)

let test_domain_parsers () =
  ok "to_url ok"      {|import String
match String.to_url "https://example.com" with
| Ok u -> "ok" | Error _ -> "err"|} "ok";
  ok "to_url err"     {|import String
match String.to_url "not-a-url" with
| Ok u -> "ok" | Error _ -> "err"|} "err";
  ok "to_ipv4 ok"     {|import String
match String.to_ipv4 "192.168.1.1" with
| Ok _ -> "ok" | Error _ -> "err"|} "ok";
  ok "to_ipv4 err"    {|import String
match String.to_ipv4 "999.0.0.1" with
| Ok _ -> "ok" | Error _ -> "err"|} "err";
  ok "to_cidr ok"     {|import String
match String.to_cidr "10.0.0.0/8" with
| Ok _ -> "ok" | Error _ -> "err"|} "ok";
  ok "to_port ok"     {|import String
match String.to_port ":8080" with
| Ok _ -> "ok" | Error _ -> "err"|} "ok";
  ok "to_port err"    {|import String
match String.to_port "8080" with
| Ok _ -> "ok" | Error _ -> "err"|} "err";
  ok "to_version ok"  {|import String
match String.to_version "1.2.3" with
| Ok _ -> "ok" | Error _ -> "err"|} "ok";
  ok "to_size ok"     {|import String
match String.to_size "10MB" with
| Ok _ -> "ok" | Error _ -> "err"|} "ok";
  ok "to_size err"    {|import String
match String.to_size "abc" with
| Ok _ -> "ok" | Error _ -> "err"|} "err";
  ok "to_date ok"     {|import String
match String.to_date "2024-01-15" with
| Ok _ -> "ok" | Error _ -> "err"|} "ok";
  ok "to_date err"    {|import String
match String.to_date "01/15/2024" with
| Ok _ -> "ok" | Error _ -> "err"|} "err";
  ok "to_time ok"     {|import String
match String.to_time "14:30:00" with
| Ok _ -> "ok" | Error _ -> "err"|} "ok";
  ok "to_datetime ok" {|import String
match String.to_datetime "2024-01-15T14:30:00Z" with
| Ok _ -> "ok" | Error _ -> "err"|} "ok";
  ok "to_duration ok" {|import String
match String.to_duration "5min" with
| Ok _ -> "ok" | Error _ -> "err"|} "ok";
  ok "to_duration err" {|import String
match String.to_duration "abc" with
| Ok _ -> "ok" | Error _ -> "err"|} "err"

(* ── Suite ──────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "String stdlib" [
    "core", [
      Alcotest.test_case "length"         `Quick test_length;
      Alcotest.test_case "case"           `Quick test_case;
      Alcotest.test_case "trim"           `Quick test_trim;
      Alcotest.test_case "slice"          `Quick test_slice;
      Alcotest.test_case "split"          `Quick test_split;
      Alcotest.test_case "predicates"     `Quick test_predicates;
      Alcotest.test_case "replace"        `Quick test_replace;
      Alcotest.test_case "repeat/reverse" `Quick test_repeat_reverse;
      Alcotest.test_case "chars"          `Quick test_chars;
      Alcotest.test_case "conversions"    `Quick test_conversions;
      Alcotest.test_case "join"           `Quick test_join;
      Alcotest.test_case "lines/words"    `Quick test_lines_words;
      Alcotest.test_case "pipeline"       `Quick test_pipeline;
    ];
    "parsing", [
      Alcotest.test_case "to_bool/path"   `Quick test_to_bool_path;
      Alcotest.test_case "domain parsers" `Quick test_domain_parsers;
    ];
  ]
