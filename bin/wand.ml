let usage () =
  print_endline "wand — a typed language for human/AI pairing";
  print_endline "";
  print_endline "Usage: wand <command> [options] [args]";
  print_endline "       wand [--dry-run|--trace] <file.wand> [args]";
  print_endline "       wand <file.wand> [args]";
  print_endline "";
  print_endline "Commands:";
  print_endline "  d   doc <name>              Print the doc string for a name";
  print_endline "  e   eval <expr>             Evaluate an expression and exit";
  print_endline "  f   fmt <file>...           Format .wand files in place";
  print_endline "  h   help [cmd]              Show this help, or help for a command";
  print_endline "  i   interactive             Start an interactive session";
  print_endline "      lsp                     Start the language server (LSP over stdio)";
  print_endline "  s   test [<file>|<dir>]...  Run test_*.wand files (default: search from here)";
  print_endline "  t   type <expr>             Typecheck an expression without evaluating";
  print_endline "  v   env [module]            List names and modules in scope";
  print_endline "  V   version                 Print the version and exit";
  print_endline "";
  print_endline "Running a script:";
  print_endline "  --dry-run        Report what the script would change, without doing it";
  print_endline "  --trace          Run it, reporting each effect as it happens";
  print_endline "";
  print_endline "Run 'wand h <command>' for command-specific help."

let usage_for sub =
  match sub with
  | "lsp" ->
    print_endline "Usage: wand lsp";
    print_endline "";
    print_endline "Start the language server, speaking the Language Server";
    print_endline "Protocol over stdin/stdout. Meant to be spawned by an";
    print_endline "editor, not run by hand."
  | "i" | "interactive" ->
    print_endline "Usage: wand i [--load <file>]...";
    print_endline "";
    print_endline "Start an interactive wand session.";
    print_endline "";
    print_endline "Options:";
    print_endline "  --load <file>   Load a .wand file before starting (repeatable)"
  | "e" | "eval" ->
    print_endline "Usage: wand e [--load <file>]... <expr>";
    print_endline "";
    print_endline "Evaluate a wand expression and print the result.";
    print_endline "If the expression contains a hole (?), typechecks only.";
    print_endline "";
    print_endline "Options:";
    print_endline "  --load <file>   Load a .wand file before evaluating (repeatable)"
  | "t" | "type" ->
    print_endline "Usage: wand t [--load <file>]... <expr>";
    print_endline "";
    print_endline "Typecheck a wand expression without evaluating it.";
    print_endline "";
    print_endline "Options:";
    print_endline "  --file <file>   Typecheck a .wand file instead of an expression";
    print_endline "  --fix           Apply the fixes the findings carry, in place (needs --file)";
    print_endline "  --load <file>   Load a .wand file before typechecking (repeatable)";
    print_endline "  --strict        Treat violation lint findings as errors";
    print_endline "  --json          Emit lint findings as JSON instead of text";
    print_endline "";
    print_endline "Lint findings are reported as warnings. Rule IDs carry";
    print_endline "what they do to a build: V- rules report a violation and";
    print_endline "--strict promotes them to errors; A- rules are advisory and";
    print_endline "always stay warnings."
  | "d" | "doc" ->
    print_endline "Usage: wand d [--load <file>]... <name>";
    print_endline "";
    print_endline "Print the doc string for a name.";
    print_endline "";
    print_endline "Options:";
    print_endline "  --json          Emit the name, type, and doc as JSON";
    print_endline "  --load <file>   Load a .wand file before looking up the name (repeatable)"
  | "v" | "env" ->
    print_endline "Usage: wand v [--load <file>]... [module]";
    print_endline "";
    print_endline "List all names and modules in scope, or one module's members:";
    print_endline "wand v List shows every List export with its signature.";
    print_endline "";
    print_endline "Options:";
    print_endline "  --json          Emit the listing as JSON";
    print_endline "  --load <file>   Load a .wand file first (repeatable)"
  | "f" | "fmt" ->
    print_endline "Usage: wand f <file.wand>...";
    print_endline "";
    print_endline "Format one or more .wand files in place (each file is";
    print_endline "overwritten with its formatted contents).";
    print_endline "Comments are preserved. An item with a comment inside it is";
    print_endline "left exactly as written, since moving a comment to the wrong";
    print_endline "expression is worse than leaving it where its author put it."
  | "s" | "test" ->
    print_endline "Usage: wand s [--json] [<file.wand>|<dir>]...";
    print_endline "";
    print_endline "Run .wand test files (let {test} = import Test;";
    print_endline "test \"label\" (fn t -> t.ok/t.eq/t.raises ...)) and report";
    print_endline "pass/fail.";
    print_endline "";
    print_endline "With no argument, searches the current directory and everything";
    print_endline "below it for files named test_*.wand — so a script's tests are";
    print_endline "found beside the script. A directory argument is searched the";
    print_endline "same way; a named file is run whatever it is called.";
    print_endline "_build, _opam, .git and node_modules are not searched.";
    print_endline "Exits nonzero if any test failed or any file errored.";
    print_endline "";
    print_endline "Options:";
    print_endline "  --json          Emit per-test results as JSON, printed when the run completes"
  | "h" | "help" ->
    print_endline "Usage: wand h [command]";
    print_endline "";
    print_endline "Show help for all commands, or detailed help for a specific command."
  | _ ->
    Printf.eprintf "Unknown command: %s\nRun 'wand h' for usage.\n" sub;
    exit 1

(* The query commands (`d`, `v`) and the test runner (`s`) take --json
   alone; `t` has its own richer flag set in parse_lint_flags below. *)
let parse_json_flag args =
  (List.mem "--json" args, List.filter (fun a -> a <> "--json") args)

let parse_loads args =
  let rec go loads rest = function
    | "--load" :: file :: tail -> go (loads @ [file]) rest tail
    | arg :: tail              -> go loads (rest @ [arg]) tail
    | []                       -> (loads, rest)
  in
  go [] [] args

(* --strict promotes violations to errors; --json emits findings for a
   tool to read rather than a person; --fix applies what the findings
   carry. *)
let parse_lint_flags args =
  let strict = ref false and json = ref false and fix = ref false in
  let rest = List.filter (fun a ->
    match a with
    | "--strict" -> strict := true; false
    | "--json"   -> json := true; false
    | "--fix"    -> fix := true; false
    | _ -> true) args
  in
  (!strict, !json, !fix, rest)

(* Returns the exit code: lints are warnings unless --strict promotes a
   violation. *)
let report_lints ~strict ~json ?(holes = []) sess src =
  match Wand.Runner.lint_session sess src with
  | Error _ ->
    (* the typecheck itself already reported this *)
    if json then print_endline "[]"; 0
  | Ok findings ->
    if json then
      (print_endline (Wand.Lint.diagnostics_json ~strict ~holes findings); 0)
    else begin
      List.iter (fun f ->
        Printf.eprintf "warning: %s\n" (Wand.Lint.to_text f)) findings;
      if strict && List.exists Wand.Lint.fails_strict findings then 1 else 0
    end

(* One-shot commands let an expression name a stdlib module without importing
   it. Importing all of them to provide that costs a disk read, lex, parse,
   full inference and eval per module, on every invocation -- paid in full by
   `wand t "1 + 2"`, the command the generate/typecheck/fix loop runs most.
   Import only the modules the input actually mentions instead. *)
let stdlib_prelude_for sources =
  let mentioned = Hashtbl.create 8 in
  List.iter (fun src ->
    match (try Some (Wand.Lexer.tokenize src) with _ -> None) with
    | None -> ()
    | Some toks ->
      List.iter (fun (tok, _) ->
        match tok with
        | Wand.Token.Upper name
          when List.mem name Wand.Typechecker.stdlib_module_names ->
          Hashtbl.replace mentioned name ()
        | _ -> ()) toks
  ) sources;
  Hashtbl.fold (fun name () acc -> ("import " ^ name) :: acc) mentioned []
  |> String.concat "\n"

(* Source text mentioning every stdlib module, for the commands that must
   load all of them. *)
let all_stdlib_imports =
  String.concat "\n"
    (List.map (fun n -> "import " ^ n) Wand.Typechecker.stdlib_module_names)

let load_files ?(sources = []) loads =
  let sess = Wand.Runner.make_session () in
  let file_sources = List.filter_map (fun path ->
    try Some (In_channel.with_open_text path In_channel.input_all)
    with Sys_error _ -> None) loads
  in
  let prelude = stdlib_prelude_for (sources @ file_sources) in
  let sess =
    if prelude = "" then sess
    else match Wand.Runner.run_session sess prelude with
      | Ok (s, _) -> s
      | Error msg ->
        (* The prelude is nothing but `import X` lines for modules the input
           mentions, so a failure here is the standard library failing to
           load. Carrying on without it produced "did you forget to import
           List?" -- an error about the caller's code, for a problem in the
           installation. *)
        Printf.eprintf "Error: %s\n" msg; exit 1
  in
  List.fold_left (fun s path ->
    match (try Ok (In_channel.with_open_text path In_channel.input_all)
           with Sys_error m -> Error m) with
    | Error m ->
      Printf.eprintf "Error loading '%s': %s\n" path m; exit 1
    | Ok src ->
      match Wand.Runner.run_session s src with
      | Ok (s', _) -> s'
      | Error m ->
        Printf.eprintf "Error loading '%s': %s\n" path m; exit 1
  ) sess loads

let () =
  let args = Array.to_list Sys.argv |> List.tl in
  match args with
  | [] | ["--help"] | ["-h"] -> usage ()
  (* Printed bare, as `wand 0.1.0`, so an installer can compare it to what it
     meant to install without parsing prose. *)
  | ["V"] | ["version"] ->
    print_endline ("wand " ^ Wand.Version.value)
  | sub :: rest when sub = "--dry-run" || sub = "--trace" ->
    (* The mode can come first, which reads better: wand --dry-run deploy.wand *)
    (match rest with
     | path :: args ->
       let mode = if sub = "--dry-run" then Wand.Runner.DryRun else Wand.Runner.Trace in
       Wand.Evaluator.exe_args_ref := args;
       (match Wand.Runner.run_file ~mode path with
        | Ok v    -> if v <> "()" then print_endline v
        | Error e -> Printf.eprintf "Error: %s\n" e; exit 1)
     | [] ->
       Printf.eprintf "Error: expected a script after %s\n" sub; exit 1)
  | sub :: rest ->
    match sub with
    | "h" | "help" ->
      (match rest with
       | []    -> usage ()
       | [cmd] -> usage_for cmd
       | _     -> usage ())
    | "i" | "interactive" ->
      let (loads, _) = parse_loads rest in
      Wand.Repl.run ~base_dir:(Sys.getcwd ()) ~loads ()
    | "lsp" ->
      exit (Wand.Lsp.serve stdin stdout)
    | "e" | "eval" ->
      let (loads, rest') = parse_loads rest in
      (match rest' with
       | [] ->
         Printf.eprintf "Error: expected expression\nRun 'wand h e' for usage.\n"; exit 1
       | [expr] ->
         let sess = load_files ~sources:[expr] loads in
         (match Wand.Runner.run_session sess expr with
          | Error msg -> Printf.eprintf "Error: %s\n" msg; exit 1
          | Ok (_, r) -> Wand.Repl.print_result r)
       | _ ->
         Printf.eprintf "Error: too many arguments\nRun 'wand h e' for usage.\n"; exit 1)
    | "t" | "type" ->
      let (strict, json, fix, rest) = parse_lint_flags rest in
      (* `wand t --file script.wand` checks a file; without it the argument is
         an expression. Stated rather than guessed from the argument's shape,
         since `deploy.wand` is itself a valid path expression. *)
      let rec take_file acc = function
        | "--file" :: path :: tl -> (Some path, List.rev_append acc tl)
        | x :: tl -> take_file (x :: acc) tl
        | [] -> (None, List.rev acc)
      in
      (match take_file [] rest with
       | None, _ when fix ->
         Printf.eprintf
           "Error: --fix rewrites a file, so it needs --file\n\
            Run 'wand h t' for usage.\n";
         exit 1
       | Some path, _ when fix ->
         (match Wand.Fix.fix_file path with
          | Error d ->
            (* An error with no applicable fix: nothing was written. *)
            if json then
              (print_endline (Wand.Diag.to_json_array ~file:path [d]); exit 1)
            else (Printf.eprintf "Error: %s\nnothing fixed\n" (Wand.Diag.legacy d); exit 1)
          | Ok applied ->
            if json then
              print_endline
                (Wand.Diag.to_json_array ~file:path
                   (List.map (fun a -> a.Wand.Fix.diag) applied))
            else
              List.iter (fun a ->
                Printf.printf "%s: %d — %s\n"
                  a.Wand.Fix.code a.Wand.Fix.line a.Wand.Fix.note) applied)
       | Some path, _ ->
         (match Wand.Runner.typecheck_file path with
          | Error d ->
            if json then
              (print_endline (Wand.Diag.to_json_array ~file:path [d]); exit 1)
            else (Printf.eprintf "Error: %s\n" (Wand.Diag.legacy d); exit 1)
          | Ok sc ->
            let holes    = sc.Wand.Runner.sc_holes in
            let findings = sc.Wand.Runner.sc_findings in
            if not json then begin
              if holes <> [] then
                List.iter (fun h -> Printf.printf "Hole: %s\n" h) holes
              else if sc.Wand.Runner.sc_type <> "Unit" then
                print_endline sc.Wand.Runner.sc_type
            end;
            if json then
              print_endline
                (Wand.Lint.diagnostics_json ~strict ~file:path ~holes findings)
            else List.iter (fun f ->
              Printf.eprintf "warning: %s\n" (Wand.Lint.to_text f)) findings;
            if strict && not json && List.exists Wand.Lint.fails_strict findings
            then exit 1)
       | None, rest ->
      let (loads, rest') = parse_loads rest in
      (match rest' with
       | [] ->
         Printf.eprintf "Error: expected expression\nRun 'wand h t' for usage.\n"; exit 1
       | [expr] ->
         let sess = load_files ~sources:[expr] loads in
         (match Wand.Runner.typecheck_session sess expr with
          | Error d ->
            if json then (print_endline (Wand.Diag.to_json_array [d]); exit 1)
            else (Printf.eprintf "Error: %s\n" (Wand.Diag.legacy d); exit 1)
          | Ok r      ->
            if not json then Wand.Repl.print_result r;
            let holes = match r with Wand.Runner.RHoles hs -> hs | _ -> [] in
            let code = report_lints ~strict ~json ~holes sess expr in
            if code <> 0 then exit code)
       | _ ->
         Printf.eprintf "Error: too many arguments\nRun 'wand h t' for usage.\n"; exit 1))
    | "d" | "doc" ->
      let (json, rest) = parse_json_flag rest in
      let (loads, rest') = parse_loads rest in
      (match rest' with
       | [] ->
         Printf.eprintf "Error: expected name\nRun 'wand h d' for usage.\n"; exit 1
       | [name] ->
         let sess = load_files ~sources:[name] loads in
         if json then
           print_endline (Wand.Runner.doc_json sess name)
         else begin
           (match Wand.Runner.lookup_type sess name with
            | Some t -> Printf.printf "%s : %s\n" name t
            | None   -> ());
           (match List.assoc_opt name sess.Wand.Runner.s_docs with
            | Some doc -> print_endline doc
            | None     -> Printf.printf "%s: no doc\n" name)
         end
       | _ ->
         Printf.eprintf "Error: too many arguments\nRun 'wand h d' for usage.\n"; exit 1)
    | "v" | "env" ->
      let (json, rest) = parse_json_flag rest in
      let (loads, rest') = parse_loads rest in
      (* `wand v <module>` needs only that module; bare `wand v` lists
         everything in scope, so it does load them all. *)
      let sess = match rest' with
        | [modname] -> load_files ~sources:[modname] loads
        | _ -> load_files ~sources:[all_stdlib_imports] loads
      in
      (match rest' with
       | [modname] when json ->
         (match Wand.Runner.module_json sess modname with
          | Ok out    -> print_endline out
          | Error msg -> Printf.eprintf "%s\n" msg; exit 1)
       | [modname] ->
         (match List.assoc_opt modname sess.Wand.Runner.s_type_env with
          | Some (Wand.Typechecker.Namespace members) ->
            let sorted = List.sort (fun (a, _) (b, _) -> String.compare a b) members in
            List.iter (fun (name, scheme) ->
              Printf.printf "%s.%s : %s\n" modname name (Wand.Typechecker.string_of_scheme scheme)
            ) sorted
          | Some _ -> Printf.eprintf "%s is a binding, not a module\n" modname; exit 1
          | None   -> Printf.eprintf "Unknown module '%s'\n" modname; exit 1)
       | _ when json ->
         print_endline (Wand.Runner.scope_json sess)
       | _ ->
         let entries = List.sort (fun (a, _) (b, _) -> String.compare a b) sess.Wand.Runner.s_type_env in
         if entries = [] then print_endline "(empty)"
         else List.iter (fun (name, s) ->
           match s with
           | Wand.Typechecker.Namespace _ -> print_endline name
           | _ -> Printf.printf "%s : %s\n" name (Wand.Typechecker.string_of_scheme s)
         ) entries)
    | "f" | "fmt" ->
      (match rest with
       | [] ->
         Printf.eprintf "Error: expected one or more files\nRun 'wand h f' for usage.\n"; exit 1
       | paths ->
         let had_error = ref false in
         List.iter (fun path ->
           match (try Ok (In_channel.with_open_text path In_channel.input_all)
                  with Sys_error m -> Error m) with
           | Error m -> had_error := true; Printf.eprintf "Error loading '%s': %s\n" path m
           | Ok src ->
             (try
                let formatted = Wand.Formatter.format_source src in
                Out_channel.with_open_text path (fun oc -> Out_channel.output_string oc formatted);
                Printf.printf "formatted %s\n" path
              with
              | (Wand.Lexer.LexError _ | Wand.Parser.ParseError _) as e ->
                had_error := true;
                Printf.eprintf "Error: %s: %s\n" path (Wand.Runner.legacy_of_exn e))
         ) paths;
         if !had_error then exit 1)
    | "s" | "test" ->
      let (json, rest) = parse_json_flag rest in
      (* No argument means the directory you are standing in, which is what
         you want after editing a script: run its tests without naming them.
         A directory argument searches it the same way; a file is run as
         given, whatever it is called. *)
      let roots = match rest with [] -> ["."] | paths -> paths in
      let missing = List.filter (fun p -> not (Sys.file_exists p)) roots in
      if missing <> [] then begin
        List.iter (fun p -> Printf.eprintf "Error: no such file or directory: %s\n" p) missing;
        exit 1
      end;
      (* A test that holds a resource should give it back when the run is
         interrupted, the same as a script. *)
      Wand.Runner.install_signal_handlers ();
      let paths = List.concat_map Wand.Runner.find_test_files roots in
      (match paths with
       | [] ->
         (match rest with
          | [] ->
            Printf.eprintf
              "No test files found under '.' — a test file is named test_*.wand.\n";
          | _ ->
            Printf.eprintf "No test files found in %s — a test file is named test_*.wand.\n"
              (String.concat ", " roots));
         exit 1
       | paths when json ->
         let results =
           Wand.Runner.with_stdout_to_stderr (fun () ->
             List.map (fun path -> (path, Wand.Runner.run_test_file path)) paths)
         in
         print_endline (Wand.Runner.test_results_json results);
         let clean = List.for_all (fun (_, r) ->
           match r with
           | Error _ -> false
           | Ok outcomes ->
             List.for_all
               (function Wand.Runner.TPass _ -> true | _ -> false) outcomes
         ) results in
         if not clean then exit 1
       | paths ->
         let multi = List.length paths > 1 in
         let had_error = ref false in
         let passed = ref 0 and failed = ref 0 in
         List.iter (fun path ->
           if multi then Printf.printf "=== %s ===\n" path;
           match Wand.Runner.run_test_file path with
           | Error m -> had_error := true; Printf.eprintf "Error loading '%s': %s\n" path m
           | Ok outcomes ->
             List.iter (fun outcome ->
               match outcome with
               | Wand.Runner.TPass label -> incr passed; Printf.printf "ok   %s\n" label
               | Wand.Runner.TFail msg   -> incr failed; Printf.printf "FAIL %s\n" msg
               | Wand.Runner.TError msg  -> incr failed; Printf.printf "FAIL %s\n" msg
             ) outcomes
         ) paths;
         Printf.printf "%d passed, %d failed\n" !passed !failed;
         if !had_error || !failed > 0 then exit 1)
    | path ->
      (* Legacy: wand <file.wand> [args] *)
      let mode, rest =
        let has f = List.mem f rest in
        let strip = List.filter (fun a -> a <> "--dry-run" && a <> "--trace") rest in
        if has "--dry-run" then (Wand.Runner.DryRun, strip)
        else if has "--trace" then (Wand.Runner.Trace, strip)
        else (Wand.Runner.Normal, strip)
      in
      Wand.Evaluator.exe_args_ref := rest;
      (* A running script can be stopped by a signal or by `exit`. Both
         unwind, so whatever the script is holding is released first, and
         the code it stops with is the one the caller expects. *)
      Wand.Runner.install_signal_handlers ();
      (match Wand.Runner.run_file ~mode path with
       | Ok v    -> if v <> "()" then print_endline v
       | Error e -> Printf.eprintf "Error: %s\n" e; exit 1
       | exception Wand.Evaluator.Interrupted code -> exit code)
