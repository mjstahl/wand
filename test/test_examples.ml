open Wand

(* The examples are the first thing a visitor runs, so a broken one costs more
   than a broken test. Four of eight were broken at once -- a removed module, a
   stale import form, a stale $() form, and a Result used as an Int -- and
   nothing noticed, because nothing ran them.

   Every example is typechecked, which is what would have caught three of those
   four. Examples that only compute are also executed; the ones that shell out
   to git/whoami/uname are not, since the sandbox is not a git repository and a
   test that depends on the host's tools fails for reasons that have nothing to
   do with the example. *)

let dir = "../examples"

(* Examples whose behavior does not depend on the host: no $(), no stdin. *)
let hermetic = ["hello.wand"; "fibonacci.wand"; "greetings.wand"; "shapes.wand"]

let example_files () =
  if not (Sys.file_exists dir) then
    Alcotest.failf "examples not found at %s (relative to test sandbox)" dir;
  Sys.readdir dir
  |> Array.to_list
  |> List.filter (fun f -> Filename.check_suffix f ".wand")
  |> List.sort String.compare

(* Typechecking needs the file's own directory as the import base, since
   party.wand imports ./greetings. *)
let typecheck path =
  let src = In_channel.with_open_text path In_channel.input_all in
  try
    let tokens = Lexer.tokenize src in
    let prog = Parser.parse_program tokens in
    let cache = Hashtbl.create 8 in
    let loading = ref [] in
    let base_dir = Filename.dirname path in
    let (imp, _) = Runner.load_imports_for ~base_dir ~cache ~loading prog in
    match Typechecker.infer_program_env ~init_tenv:imp.tenv ~init_env:imp.type_env prog with
    | Ok _ -> Ok ()
    | Error msg -> Error ("type error: " ^ msg)
  with
  | Lexer.LexError msg    -> Error ("lex error: " ^ msg)
  | Parser.ParseError msg -> Error ("parse error: " ^ msg)
  | Typechecker.TypeError msg -> Error ("type error: " ^ msg)
  | Failure msg           -> Error msg

let test_all_typecheck () =
  List.iter (fun name ->
    match typecheck (Filename.concat dir name) with
    | Ok () -> ()
    | Error msg -> Alcotest.failf "examples/%s does not typecheck: %s" name msg
  ) (example_files ())

let test_hermetic_run () =
  List.iter (fun name ->
    match Runner.run_file (Filename.concat dir name) with
    | Ok _ -> ()
    | Error msg -> Alcotest.failf "examples/%s failed to run: %s" name msg
  ) hermetic

(* If an example is added, it is covered by the typecheck sweep automatically;
   this keeps the hermetic list from naming a file that no longer exists. *)
let test_hermetic_list_is_current () =
  let all = example_files () in
  List.iter (fun name ->
    if not (List.mem name all) then
      Alcotest.failf "hermetic list names %s, which is not in examples/" name
  ) hermetic

let () =
  Alcotest.run "Examples" [
    "all", [
      Alcotest.test_case "typecheck"      `Quick test_all_typecheck;
      Alcotest.test_case "hermetic list"  `Quick test_hermetic_list_is_current;
    ];
    "hermetic", [
      Alcotest.test_case "run" `Quick test_hermetic_run;
    ];
  ]
