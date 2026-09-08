open Wand

(* The reading layer, straight against the OCaml side. The scalar rules are
   the reason this module exists rather than a call to the library's own
   `of_string`, so they are what is checked hardest: `of_string` resolves
   `no` to the boolean false, and a compose file read that way is wrong
   without saying so. *)

let json = Alcotest.testable Yojson.Basic.pp Yojson.Basic.equal

let parses src expected () =
  match Yaml_read.parse src with
  | Ok got -> Alcotest.check json src expected got
  | Error e -> Alcotest.failf "%s: %s" src e

(* ── the 1.2 core schema ─────────────────────────────────────────────── *)

let scalars =
  [
    (* The three rows the design record turns on. *)
    ("on is a key, not a boolean", "on: push", `Assoc [ ("on", `String "push") ]);
    ( "no is a word, not false",
      "restart: no",
      `Assoc [ ("restart", `String "no") ] );
    ( "a port is not base sixty",
      "ports:\n  - 2200:22\n",
      `Assoc [ ("ports", `List [ `String "2200:22" ]) ] );
    ("NO is a country", "country: NO", `Assoc [ ("country", `String "NO") ]);
    ("yes is a word", "a: yes", `Assoc [ ("a", `String "yes") ]);
    ("off is a word", "a: off", `Assoc [ ("a", `String "off") ]);
    (* What the core schema does resolve. *)
    ("true resolves", "a: true", `Assoc [ ("a", `Bool true) ]);
    ("False resolves", "a: False", `Assoc [ ("a", `Bool false) ]);
    ("an int resolves", "a: 42", `Assoc [ ("a", `Int 42) ]);
    ("a negative int", "a: -7", `Assoc [ ("a", `Int (-7)) ]);
    ("hex", "a: 0x1f", `Assoc [ ("a", `Int 31) ]);
    ("octal", "a: 0o17", `Assoc [ ("a", `Int 15) ]);
    ("a float", "a: 1.5", `Assoc [ ("a", `Float 1.5) ]);
    ("an exponent", "a: 6.8e2", `Assoc [ ("a", `Float 680.) ]);
    ("null", "a: null", `Assoc [ ("a", `Null) ]);
    ("a tilde is null", "a: ~", `Assoc [ ("a", `Null) ]);
    ("an empty value is null", "a:", `Assoc [ ("a", `Null) ]);
    (* Quoting says string, whatever the text looks like. This is how a
       chart version and a port are written correctly. *)
    ("a quoted number is a string", "a: \"42\"", `Assoc [ ("a", `String "42") ]);
    ( "a quoted version is a string",
      "a: \"1.10\"",
      `Assoc [ ("a", `String "1.10") ] );
    ("a quoted bool is a string", "a: 'true'", `Assoc [ ("a", `String "true") ]);
    (* And the row that survives both schemas, which the docs have to say
       loudly: an unquoted chart version is a float and loses its zero. *)
    ("an unquoted 1.10 is a float", "a: 1.10", `Assoc [ ("a", `Float 1.1) ]);
    (* Underscores are a 1.1 idea. 1.2 core reads this as a string. *)
    ("underscores do not group digits", "a: 1_000", `Assoc [ ("a", `String "1_000") ]);
  ]

(* ── shape ───────────────────────────────────────────────────────────── *)

let shapes =
  [
    ("a sequence", "- 1\n- 2\n", `List [ `Int 1; `Int 2 ]);
    ( "nesting",
      "a:\n  b:\n    - 1\n",
      `Assoc [ ("a", `Assoc [ ("b", `List [ `Int 1 ]) ]) ] );
    ("flow style", "{a: 1, b: [2, 3]}",
     `Assoc [ ("a", `Int 1); ("b", `List [ `Int 2; `Int 3 ]) ]);
    ("an empty input is an empty document", "", `Null);
    (* A key that looks like a number is still a key, because Map is keyed
       by String and these formats have no other kind. *)
    ("a numeric key is a string", "1: a", `Assoc [ ("1", `String "a") ]);
  ]

(* ── anchors, aliases and merge keys ─────────────────────────────────── *)

let anchors =
  [
    ( "an alias copies the node",
      "a: &x 1\nb: *x\n",
      `Assoc [ ("a", `Int 1); ("b", `Int 1) ] );
    ( "an alias copies a mapping",
      "base: &b\n  x: 1\nuse: *b\n",
      `Assoc
        [ ("base", `Assoc [ ("x", `Int 1) ]); ("use", `Assoc [ ("x", `Int 1) ]) ]
    );
    ( "a merge key brings the keys in",
      "base: &b\n  x: 1\n  y: 2\nsvc:\n  <<: *b\n  y: 9\n",
      `Assoc
        [
          ("base", `Assoc [ ("x", `Int 1); ("y", `Int 2) ]);
          ("svc", `Assoc [ ("y", `Int 9); ("x", `Int 1) ]);
        ] );
    (* The explicit key wins wherever it is written, which is what the
       merge key means -- here it is written above the `<<`. *)
    ( "an explicit key above the merge still wins",
      "base: &b\n  y: 2\nsvc:\n  y: 9\n  <<: *b\n",
      `Assoc
        [ ("base", `Assoc [ ("y", `Int 2) ]); ("svc", `Assoc [ ("y", `Int 9) ]) ]
    );
    ( "a sequence of merges takes the earlier one",
      "a: &a\n  k: 1\nb: &b\n  k: 2\nc:\n  <<: [*a, *b]\n",
      `Assoc
        [
          ("a", `Assoc [ ("k", `Int 1) ]);
          ("b", `Assoc [ ("k", `Int 2) ]);
          ("c", `Assoc [ ("k", `Int 1) ]);
        ] );
  ]

(* ── documents ───────────────────────────────────────────────────────── *)

let test_parse_all () =
  match Yaml_read.parse_all "a: 1\n---\nb: 2\n" with
  | Ok [ d1; d2 ] ->
    Alcotest.check json "first" (`Assoc [ ("a", `Int 1) ]) d1;
    Alcotest.check json "second" (`Assoc [ ("b", `Int 2) ]) d2
  | Ok ds -> Alcotest.failf "expected two documents, got %d" (List.length ds)
  | Error e -> Alcotest.fail e

(* Taking the first document silently is how a script checks one third of a
   manifest and reports that everything passed. *)
let test_parse_refuses_many () =
  match Yaml_read.parse "a: 1\n---\nb: 2\n" with
  | Ok _ -> Alcotest.fail "parse read a two-document file without complaining"
  | Error e ->
    Alcotest.(check bool)
      (Printf.sprintf "the message counts them: %S" e)
      true
      (String.length e > 0
      && Option.is_some (String.index_opt e '2')
      && Option.is_some (String.index_opt e 'p'))

let test_anchors_do_not_cross_documents () =
  match Yaml_read.parse_all "a: &x 1\n---\nb: *x\n" with
  | Ok _ -> Alcotest.fail "an alias reached into the document above it"
  | Error _ -> ()

let () =
  let case (name, src, expected) =
    Alcotest.test_case name `Quick (parses src expected)
  in
  Alcotest.run "YAML reading"
    [
      ("the 1.2 core schema", List.map case scalars);
      ("shape", List.map case shapes);
      ("anchors and merges", List.map case anchors);
      ( "documents",
        [
          Alcotest.test_case "parse_all splits on ---" `Quick test_parse_all;
          Alcotest.test_case "parse refuses more than one" `Quick
            test_parse_refuses_many;
          Alcotest.test_case "anchors are per document" `Quick
            test_anchors_do_not_cross_documents;
        ] );
    ]
