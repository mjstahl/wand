open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

(* ── join ────────────────────────────────────────────────────────────────── *)

let test_join () =
  ok "absolute + segment" {|import Path
Path.join /usr/local /bin|} "/usr/local/bin";
  ok "relative"           {|import Path
Path.join ./foo /bar|} "./foo/bar";
  ok "nested"             {|import Path
Path.join /var /log|} "/var/log"

(* ── parent / dirname ───────────────────────────────────────────────────── *)

let test_parent () =
  ok "parent"          {|import Path
Path.parent /usr/local/bin|} "/usr/local";
  ok "dirname alias"   {|import Path
Path.dirname /usr/local/bin|} "/usr/local";
  ok "top-level"       {|import Path
Path.parent /usr|} "/"

(* ── basename ───────────────────────────────────────────────────────────── *)

let test_basename () =
  ok "with ext"    {|import Path
Path.basename /usr/local/bin/wand|} "wand";
  ok "file"        {|import Path
Path.basename /etc/hosts|} "hosts"

(* ── extension ──────────────────────────────────────────────────────────── *)

let test_extension () =
  ok "dot txt"      {|import Path
Path.extension /foo/bar.txt|} ".txt";
  ok "no extension" {|import Path
Path.extension /foo/bar|} "";
  ok "with_extension add" {|import Path
Path.with_extension ".ml" /foo/bar|} "/foo/bar.ml";
  ok "with_extension replace" {|import Path
Path.with_extension ".ml" /foo/bar.wand|} "/foo/bar.ml"

(* ── is_absolute? / is_relative? ────────────────────────────────────────── *)

let test_absolute_relative () =
  ok "absolute /"    {|import Path
Path.is_absolute? /etc/hosts|} "true";
  ok "relative ./"   {|import Path
Path.is_absolute? ./foo|} "false";
  ok "is_relative ./"   {|import Path
Path.is_relative? ./foo|} "true";
  ok "is_relative /"    {|import Path
Path.is_relative? /usr|} "false"

(* ── normalize ───────────────────────────────────────────────────────────── *)

let test_normalize () =
  ok "double slash"  {|import Path
Path.normalize /usr//local|} "/usr/local";
  ok "dot component" {|import Path
Path.normalize /usr/./local|} "/usr/local";
  ok "dotdot"        {|import Path
Path.normalize /usr/local/../bin|} "/usr/bin"

(* ── to_string / of_string ───────────────────────────────────────────────── *)

let test_conversions () =
  ok "to_string"  {|import Path
Path.to_string /etc/hosts|} "/etc/hosts";
  ok "of_string"  {|import Path
Path.to_string (Path.of_string "/etc/hosts")|} "/etc/hosts"

(* ── components ──────────────────────────────────────────────────────────── *)

let test_components () =
  ok "absolute"  {|import Path
Path.components /usr/local/bin|} "[usr, local, bin]";
  ok "relative"  {|import Path
Path.components ./foo/bar|} "[., foo, bar]"

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Path module" [
    "operations", [
      Alcotest.test_case "join"              `Quick test_join;
      Alcotest.test_case "parent/dirname"    `Quick test_parent;
      Alcotest.test_case "basename"          `Quick test_basename;
      Alcotest.test_case "extension"         `Quick test_extension;
      Alcotest.test_case "absolute/relative" `Quick test_absolute_relative;
      Alcotest.test_case "normalize"         `Quick test_normalize;
      Alcotest.test_case "conversions"       `Quick test_conversions;
      Alcotest.test_case "components"        `Quick test_components;
    ];
  ]
