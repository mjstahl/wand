open Wand

let run s = Runner.run_string s

let ok label input expected =
  Alcotest.(check (result string string)) label (Ok expected) (run input)

(* ── constructors ───────────────────────────────────────────────────────── *)

let test_constructors () =
  ok "zero"    {|import Duration
Duration.zero|} "0s";
  ok "seconds" {|import Duration
Duration.seconds 30|} "30s";
  ok "minutes" {|import Duration
Duration.minutes 5|} "5m";
  ok "hours"   {|import Duration
Duration.hours 2|} "2h";
  ok "days"    {|import Duration
Duration.days 3|} "3d";
  ok "weeks"   {|import Duration
Duration.weeks 1|} "1w"

(* ── literals round-trip via format ─────────────────────────────────────── *)

let test_format () =
  ok "simple"   {|import Duration
Duration.format 5min|} "5m";
  ok "compound" {|import Duration
Duration.format 1h30m|} "1h30m";
  ok "millis"   {|import Duration
Duration.format 500ms|} "500ms";
  ok "complex"  {|import Duration
Duration.format 2d12h30m|} "2d12h30m"

(* ── to_ms ───────────────────────────────────────────────────────────────── *)

let test_to_ms () =
  ok "1s"    {|import Duration
Duration.to_ms 1s|} "1000";
  ok "1min"  {|import Duration
Duration.to_ms 1min|} "60000";
  ok "1h"    {|import Duration
Duration.to_ms 1h|} "3600000";
  ok "500ms" {|import Duration
Duration.to_ms 500ms|} "500"

(* ── add ─────────────────────────────────────────────────────────────────── *)

let test_add () =
  ok "hours + minutes" {|import Duration
Duration.format (Duration.add (Duration.hours 1) (Duration.minutes 30))|} "1h30m";
  ok "seconds + seconds" {|import Duration
Duration.format (Duration.add (Duration.seconds 30) (Duration.seconds 45))|} "1m15s";
  ok "add zero" {|import Duration
Duration.format (Duration.add 5min Duration.zero)|} "5m"

(* ── sub ─────────────────────────────────────────────────────────────────── *)

let test_sub () =
  ok "hours - minutes" {|import Duration
Duration.format (Duration.sub (Duration.hours 2) (Duration.minutes 30))|} "1h30m";
  ok "clamp to zero"   {|import Duration
Duration.format (Duration.sub (Duration.minutes 1) (Duration.hours 1))|} "0s"

(* ── scale ───────────────────────────────────────────────────────────────── *)

let test_scale () =
  ok "double"  {|import Duration
Duration.format (Duration.scale 2 (Duration.hours 1))|} "2h";
  ok "triple"  {|import Duration
Duration.format (Duration.scale 3 30s)|} "1m30s";
  ok "zero"    {|import Duration
Duration.format (Duration.scale 0 1h)|} "0s"

(* ── pipeline ────────────────────────────────────────────────────────────── *)

let test_pipeline () =
  ok "pipe"  {|import Duration
Duration.seconds 90 |> Duration.format|} "1m30s"

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Duration module" [
    "core", [
      Alcotest.test_case "constructors" `Quick test_constructors;
      Alcotest.test_case "format"       `Quick test_format;
      Alcotest.test_case "to_ms"        `Quick test_to_ms;
      Alcotest.test_case "add"          `Quick test_add;
      Alcotest.test_case "sub"          `Quick test_sub;
      Alcotest.test_case "scale"        `Quick test_scale;
      Alcotest.test_case "pipeline"     `Quick test_pipeline;
    ];
  ]
