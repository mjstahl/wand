open Wand

(* ── Glob lexer ──────────────────────────────────────────────────────────────── *)

let test_glob_tokens () =
  let toks src =
    Lexer.tokenize_plain src
    |> List.filter (fun t -> t <> Token.EOF && t <> Token.Newline)
  in
  Alcotest.(check (list (testable Token.pp Token.equal))) "*.wand"
    [Token.Glob "*.wand"] (toks "*.wand");
  Alcotest.(check (list (testable Token.pp Token.equal))) "**"
    [Token.Glob "**"] (toks "**");
  Alcotest.(check (list (testable Token.pp Token.equal))) "./**/*.ml"
    [Token.Glob "./**/*.ml"] (toks "./**/*.ml");
  Alcotest.(check (list (testable Token.pp Token.equal))) "./*.wand"
    [Token.Glob "./*.wand"] (toks "./*.wand");
  (* paths without wildcards are still Path, not Glob *)
  Alcotest.(check (list (testable Token.pp Token.equal))) "/etc/hosts is Path"
    [Token.Path "/etc/hosts"] (toks "/etc/hosts")

(* ── Suite ───────────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Glob" [
    "lexer", [
      Alcotest.test_case "glob tokens"    `Quick test_glob_tokens;
    ];
  ]
