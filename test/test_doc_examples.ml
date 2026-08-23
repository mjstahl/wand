open Wand

(* An example in a doc string is read by someone deciding how to call a
   function, and a wrong one is read with the same trust as a right one. So
   they are run, and the exit code is the answer -- `tools/check_docs.wand`
   is that answer over the whole standard library.

   Two halves here: what counts as an example, and what running one decides. *)

(* ── What counts as an example ────────────────────────────────────────────── *)

let examples = Alcotest.(list (pair string (list string)))

let extracts label doc expected =
  Alcotest.(check examples) label expected (Runner.doc_examples doc)

let test_one_example () =
  extracts "prompt, then what it produces"
    "Keep the ones that pass.\n\n>> List.filter p xs\n[2, 3] : List Int"
    [("List.filter p xs", ["[2, 3] : List Int"])]

let test_prose_alone_has_none () =
  extracts "no prompt, no example" "Just a description." []

let test_blank_line_ends_it () =
  (* A doc string may carry an example and then go on talking. What comes
     after the blank line is prose, not more output. *)
  extracts "a blank line ends what the example produces"
    ">> 1 + 2\n3 : Int\n\nAnd a note about it."
    [("1 + 2", ["3 : Int"])]

let test_several_output_lines () =
  (* What an example prints is part of what it claims. *)
  extracts "everything under the prompt"
    ">> List.each (fn x -> IO.println \"%{x}\") [1, 2]\n1\n2"
    [("List.each (fn x -> IO.println \"%{x}\") [1, 2]", ["1"; "2"])]

let test_a_prompt_with_nothing_under_it () =
  (* A step, not a claim: it is run so the next one can use what it bound,
     and nothing is compared against it. *)
  extracts "a setup step claims nothing"
    ">> let counts = {a = 1}\n>> Map.get \"a\" counts\nSome(1) : Option Int"
    [("let counts = {a = 1}", []);
     ("Map.get \"a\" counts", ["Some(1) : Option Int"])]

(* ── What running one decides ─────────────────────────────────────────────── *)

let wand_binary =
  let dir = Filename.dirname (Filename.dirname Sys.executable_name) in
  Filename.concat (Filename.concat dir "bin") "wand.exe"

let run args =
  let cmd = String.concat " " (List.map Filename.quote (wand_binary :: args)) in
  let ic = Unix.open_process_in (cmd ^ " 2>&1") in
  let out = In_channel.input_all ic in
  let code = match Unix.close_process_in ic with
    | Unix.WEXITED n -> n
    | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n
  in
  (code, out)

let with_module doc f =
  let path = Filename.temp_file "wand_doc_" ".wand" in
  Out_channel.with_open_text path (fun oc ->
    Out_channel.output_string oc
      (Printf.sprintf "import List\nimport Map\n\n%s\nlet subject xs = List.length xs\n"
         doc));
  Fun.protect ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () -> f path)

let test_an_example_that_holds () =
  with_module "-- Count them.\n--\n-- >> List.length [1, 2, 3]\n-- 3 : Int"
    (fun path ->
       let (code, out) = run ["d"; "-t"; "--load"; path; "subject"] in
       Alcotest.(check int) "an example that holds passes" 0 code;
       (* Nothing to say. A gate that talks on success trains its reader to
          stop reading it. *)
       Alcotest.(check string) "and says nothing" "" out)

let test_an_example_that_does_not () =
  with_module "-- Count them.\n--\n-- >> List.length [1, 2, 3]\n-- 4 : Int"
    (fun path ->
       let (code, out) = run ["d"; "-t"; "--load"; path; "subject"] in
       Alcotest.(check int) "a wrong example fails" 1 code;
       (* The report has to say what was claimed and what happened, or the
          reader has to go and run it themselves. *)
       if not (Lint.contains out "4 : Int" && Lint.contains out "3 : Int") then
         Alcotest.failf "the report does not show both sides:\n%s" out)

let test_a_setup_step_is_not_checked () =
  with_module
    "-- Look one up.\n--\n-- >> let counts = {a = 1}\n\
     -- >> Map.get \"a\" counts\n-- Some(1) : Option Int"
    (fun path ->
       let (code, out) = run ["d"; "-t"; "--load"; path; "subject"] in
       Alcotest.(check int) "the step runs and the example holds" 0 code;
       Alcotest.(check string) "and says nothing" "" out)

let test_a_module_runs_all_of_them () =
  let (code, out) = run ["d"; "-t"; "List"] in
  Alcotest.(check int) "the standard library's own hold" 0 code;
  Alcotest.(check string) "with nothing to report" "" out

(* Silence says every example held. It would say the same if there were no
   examples at all, and a module name that no longer resolves would then
   pass the gate rather than fail it. So the count is pinned where it can be
   seen: every documented name in `List` carries one. *)
let test_the_module_actually_has_examples () =
  let sess = Runner.make_session () in
  match Runner.run_session sess "import List" with
  | Error m -> Alcotest.failf "could not load List: %s" m
  | Ok (sess, _) ->
    let documented =
      List.filter (fun (name, doc) ->
        String.length name > 5 && String.sub name 0 5 = "List."
        && Runner.doc_examples doc <> [])
        sess.Runner.s_docs
    in
    if List.length documented < 25 then
      Alcotest.failf "expected List to document examples, found %d"
        (List.length documented)

let test_execute_shows_what_it_does () =
  (* `-x` does not judge: it prints the doc with the examples run where they
     stand, so a stale one is visible against what the file claims. *)
  with_module "-- Count them.\n--\n-- >> List.length [1, 2, 3]\n-- 4 : Int"
    (fun path ->
       let (code, out) = run ["d"; "-x"; "--load"; path; "subject"] in
       Alcotest.(check int) "showing is not judging" 0 code;
       if not (Lint.contains out ">> List.length [1, 2, 3]") then
         Alcotest.failf "expected the example to be shown:\n%s" out;
       if not (Lint.contains out "3 : Int") then
         Alcotest.failf "expected what it really produces:\n%s" out;
       if Lint.contains out "4 : Int" then
         Alcotest.failf "expected the stale claim to be replaced:\n%s" out)

let test_the_two_flags_are_different_questions () =
  let (code, out) = run ["d"; "-x"; "-t"; "List.map"] in
  Alcotest.(check int) "asking both at once is refused" 1 code;
  if not (Lint.contains out "Pick one") then
    Alcotest.failf "expected it to say why:\n%s" out

let test_a_module_without_examples_passes () =
  (* Modules gain examples one at a time, and the gate has to pass on the
     way there. A name asked for by itself is a question, and gets an
     answer instead. *)
  let (code, out) = run ["d"; "-t"; "Proc"] in
  Alcotest.(check int) "a module with none is not a failure" 0 code;
  Alcotest.(check string) "and says nothing under -t" "" out

let test_a_name_without_examples_says_so () =
  with_module "-- Count them, with nothing to show for it."
    (fun path ->
       let (code, out) = run ["d"; "-t"; "--load"; path; "subject"] in
       Alcotest.(check int) "a name with none is an error" 1 code;
       if not (Lint.contains out "no examples") then
         Alcotest.failf "expected it to say there are none:\n%s" out)

let () =
  Alcotest.run "doc examples" [
    "what counts as an example", [
      Alcotest.test_case "one example"            `Quick test_one_example;
      Alcotest.test_case "prose alone"            `Quick test_prose_alone_has_none;
      Alcotest.test_case "a blank line ends it"   `Quick test_blank_line_ends_it;
      Alcotest.test_case "several output lines"   `Quick test_several_output_lines;
      Alcotest.test_case "a prompt claiming nothing" `Quick
        test_a_prompt_with_nothing_under_it;
    ];
    "what running one decides", [
      Alcotest.test_case "one that holds"         `Quick test_an_example_that_holds;
      Alcotest.test_case "one that does not"      `Quick test_an_example_that_does_not;
      Alcotest.test_case "a setup step"           `Quick test_a_setup_step_is_not_checked;
      Alcotest.test_case "a whole module"         `Quick test_a_module_runs_all_of_them;
      Alcotest.test_case "the module has some"    `Quick
        test_the_module_actually_has_examples;
      Alcotest.test_case "a module with none"     `Quick
        test_a_module_without_examples_passes;
      Alcotest.test_case "a name with none"       `Quick
        test_a_name_without_examples_says_so;
      Alcotest.test_case "showing, not judging"   `Quick
        test_execute_shows_what_it_does;
      Alcotest.test_case "both at once"           `Quick
        test_the_two_flags_are_different_questions;
    ];
  ]
