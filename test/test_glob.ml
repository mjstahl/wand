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
    [Token.Path "/etc/hosts"] (toks "/etc/hosts");
  (* A character class runs to its `]`. *)
  Alcotest.(check (list (testable Token.pp Token.equal))) "./f[0-9].txt"
    [Token.Glob "./f[0-9].txt"] (toks "./f[0-9].txt");
  (* And a `[` with no `]` to reach is a literal `[`, as it is to fnmatch(3).
     The scan for the `]` used to stop only at the end of the file, so an
     unmatched one turned everything after it into a single glob -- including
     the newline that ends the statement, and any bracket written after it,
     which is how `wand f` came to write source that would not parse. Found
     by test/fuzz. *)
  Alcotest.(check (list (testable Token.pp Token.equal))) "an unmatched ["
    [Token.Glob "*[.0"; Token.Ident "x"] (toks "*[.0 x");
  Alcotest.(check (list (testable Token.pp Token.equal))) "and one at a line end"
    [Token.Glob "./a[bc"] (toks "./a[bc\n");
  (* The closing bracket is the one that mattered: it is what `wand f` wrote
     after the glob, and the glob ate it. The opening one is spelled a space
     away because a bracket written straight onto a star is the other hazard
     -- the one the lexer reads as a block comment -- and keeping them apart
     is `Formatter.opener`'s business, not this. *)
  Alcotest.(check (list (testable Token.pp Token.equal))) "a bracket after it"
    [Token.LParen; Token.Glob "*[.0"; Token.RParen] (toks "( *[.0)")

(* ── Suite ───────────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Glob" [
    "lexer", [
      Alcotest.test_case "glob tokens"    `Quick test_glob_tokens;
    ];
  ]
