open Wand
open Shell_scan

let word = Alcotest.testable
    (fun fmt -> function
       | Literal w  -> Format.fprintf fmt "Literal %S" w
       | Dynamic    -> Format.fprintf fmt "Dynamic"
       | Compound w -> Format.fprintf fmt "Compound %S" w)
    (=)

let check label text expected =
  Alcotest.(check (list word)) label expected (scan_string text).words

let check_segs label segs expected_words expected_raw =
  let s = scan segs in
  Alcotest.(check (list word)) label expected_words s.words;
  Alcotest.(check bool) (label ^ " raw_tail") expected_raw s.raw_tail

let test_single () =
  check "one word" "git" [Literal "git"];
  check "with args" "git status --short" [Literal "git"];
  check "path-qualified" "/usr/bin/git status" [Literal "/usr/bin/git"];
  check "empty" "" [];
  check "spaces only" "   " []

let test_operators () =
  check "pipeline" "git log | grep fix | wc -l"
    [Literal "git"; Literal "grep"; Literal "wc"];
  check "and chain" "make build && make test"
    [Literal "make"; Literal "make"];
  check "or chain" "test -f x || touch x"
    [Literal "test"; Literal "touch"];
  check "semicolons" "cd /tmp; ls; pwd"
    [Literal "cd"; Literal "ls"; Literal "pwd"];
  check "background" "sleep 5 & echo done"
    [Literal "sleep"; Literal "echo"];
  check "trailing operator" "ls |" [Literal "ls"]

let test_quotes () =
  check "quoted pipe is an argument" "echo \"a | b\" | wc"
    [Literal "echo"; Literal "wc"];
  check "single quotes" "grep 'a && b' log" [Literal "grep"];
  check "escaped space joins a word" "run\\ me now" [Literal "run me"];
  check "backtick contents are opaque" "echo `git rev-parse HEAD`"
    [Literal "echo"]

let test_assignments () =
  check "prefix assignment" "FOO=1 git status" [Literal "git"];
  check "several prefixes" "A=1 B=2 make" [Literal "make"];
  check "assignment only" "FOO=1" [];
  check "assignment after command is an argument" "env A=1 cmd"
    [Literal "env"]

let test_redirections () =
  check "leading redirect" "> /tmp/x echo hi" [Literal "echo"];
  check "fd redirect" "cmd 2> /dev/null | wc" [Literal "cmd"; Literal "wc"];
  check "dup redirect" "cmd 2>&1 | tee log" [Literal "cmd"; Literal "tee"];
  check "append" "echo x >> log" [Literal "echo"]

let test_compounds () =
  (* Precision past the first Compound does not matter -- one is already a
     type error under a narrowed manifest -- so words directly after a
     reserved word read as its arguments, not as commands. *)
  check "for loop" "for f in *.txt; do git add $f; done"
    [Compound "for"; Compound "do"; Compound "done"];
  check "if" "if true; then ls; fi"
    [Compound "if"; Compound "then"; Compound "fi"];
  check "brace group" "{ ls; pwd; }"
    [Compound "{"; Literal "pwd"; Compound "}"];
  (* `time` is a wrapper, not control flow. *)
  check "time wraps" "time git status" [Literal "time"]

let test_subshells () =
  check "inline substitution is opaque"
    "git log $(git merge-base a b)..HEAD" [Literal "git"];
  check "operators inside substitution stay inside"
    "echo $(ls | wc -l) | cat" [Literal "echo"; Literal "cat"]

let test_holes () =
  check_segs "quoted hole in argument position"
    [Lit "git commit -m "; QuotedHole] [Literal "git"] false;
  check_segs "quoted hole as the command word"
    [QuotedHole; Lit " --version"] [Dynamic] false;
  check_segs "quoted hole fused to a literal"
    [Lit "git-"; QuotedHole; Lit " sub"] [Dynamic] false;
  check_segs "raw hole as the command word"
    [RawHole; Lit " --version"] [Dynamic] true;
  check_segs "raw hole in argument position poisons the tail"
    [Lit "ls "; RawHole; Lit " | rm -rf /"] [Literal "ls"] true;
  check_segs "positions before a raw hole are still read"
    [Lit "git add . && "; RawHole] [Literal "git"; Dynamic] true

let test_render_entry () =
  let bare w = Alcotest.(check string) (w ^ " stays bare") w (render_entry w) in
  let quoted w =
    Alcotest.(check string) (w ^ " needs quotes")
      ("\"" ^ w ^ "\"") (render_entry w)
  in
  bare "git";
  bare "docker-compose";
  bare "node.js";
  bare "g++";
  bare "apt-get";
  quoted "7zip";           (* leading digit lexes as a number *)
  quoted "my tool";        (* whitespace *)
  quoted "a--b";           (* -- starts a comment *)
  quoted "do";             (* a keyword, not an Ident *)
  quoted "git-do";         (* keyword chunk breaks the chain *)
  quoted "/opt/bin/deploy" (* paths are accepted bare on input, quoted on output *)

let test_allowed () =
  let allow = ["git"; "/opt/bin/deploy"] in
  Alcotest.(check bool) "bare entry, bare word" true (allowed ~allow "git");
  Alcotest.(check bool) "bare entry admits a path" true
    (allowed ~allow "/usr/bin/git");
  Alcotest.(check bool) "slash entry is exact" true
    (allowed ~allow "/opt/bin/deploy");
  Alcotest.(check bool) "slash entry rejects other paths" false
    (allowed ~allow "/usr/local/bin/deploy");
  Alcotest.(check bool) "slash entry rejects the basename" false
    (allowed ~allow "deploy");
  Alcotest.(check bool) "unlisted" false (allowed ~allow "curl")

(* ── The spawn-time check, end to end ─────────────────────────────────────
   These live here rather than in test/wand because a dynamic command word
   under a narrowed manifest rightly carries a V-SHELL1 finding, and the
   test/wand corpus must lint clean. *)

let run label src expected =
  match Runner.run_string src with
  | Ok v -> Alcotest.(check string) label expected v
  | Error m -> Alcotest.failf "%s: failed to run: %s" label m

let test_spawn_check () =
  run "an allowed dynamic word spawns"
    "uses {Shell(echo)}\nlet r c = $(%!{c} hi)\nr \"echo\""
    "hi";
  run "a disallowed dynamic word is refused, catchably"
    "uses {Shell(echo)}\nimport String\nlet r c = $(%!{c} hi)\n\
     match try r \"printf\" with\n\
     | Ok _ -> \"ran\"\n\
     | Error why -> if String.contains? \"does not allow\" why then \"refused\" else why"
    "refused";
  run "a word that resolves to control flow is refused"
    "uses {Shell(echo)}\nimport String\nlet r c = $(%!{c} true; echo x; done)\n\
     match try r \"while\" with\n\
     | Ok _ -> \"ran\"\n\
     | Error why -> if String.contains? \"control flow\" why then \"refused\" else why"
    "refused";
  run "a mock intercepts before the spawn check"
    "uses {Shell(git)}\nimport Test\n\
     let go () = let c = \"curl\" in $(%!{c} https://example.com)\n\
     Test.with_shell [(\"curl\", \"mocked\")] go"
    "mocked";
  run "jurisdiction survives Par's forwarding"
    "uses {Shell(echo)}\nimport Par\nimport List\nimport String\n\
     let r c = $(%!{c} hi)\n\
     let outcomes = Par.map 2 r [\"echo\", \"printf\", \"echo\"]\n\
     let show o = match o with | Ok v -> v | Error _ -> \"refused\"\n\
     List.map show outcomes |> (fn ws -> String.join \",\" ws)"
    "hi,refused,hi"

let () =
  Alcotest.run "shell scan" [
    "positions", [
      Alcotest.test_case "single"       `Quick test_single;
      Alcotest.test_case "operators"    `Quick test_operators;
      Alcotest.test_case "quotes"       `Quick test_quotes;
      Alcotest.test_case "assignments"  `Quick test_assignments;
      Alcotest.test_case "redirections" `Quick test_redirections;
      Alcotest.test_case "compounds"    `Quick test_compounds;
      Alcotest.test_case "subshells"    `Quick test_subshells;
      Alcotest.test_case "holes"        `Quick test_holes;
    ];
    "allowlist", [
      Alcotest.test_case "matching" `Quick test_allowed;
      Alcotest.test_case "render"   `Quick test_render_entry;
    ];
    "spawn check", [
      Alcotest.test_case "end to end" `Quick test_spawn_check;
    ];
  ]
