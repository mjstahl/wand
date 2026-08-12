let usage () =
  print_endline "wand — a typed language for human/AI pairing";
  print_endline "";
  print_endline "Usage: wand <command> [options] [args]";
  print_endline "       wand [--dry-run|--trace] <file.wand> [args]";
  print_endline "       wand <file.wand> [args]";
  print_endline "";
  print_endline "Commands:";
  print_endline "  i, interactive   Start an interactive session";
  print_endline "  e, eval <expr>   Evaluate an expression and exit";
  print_endline "  t, type <expr>   Typecheck an expression without evaluating";
  print_endline "  d, doc  <name>   Print the doc string for a name";
  print_endline "  env              List all names and modules in scope";
  print_endline "  fmt, format <file>  Format a .wand file in place";
  print_endline "  test <file>...   Run one or more .wand test files";
  print_endline "  h, help [cmd]    Show this help, or help for a command";
  print_endline "";
  print_endline "Running a script:";
  print_endline "  --dry-run        Report what the script would change, without doing it";
  print_endline "  --trace          Run it, reporting each effect as it happens";
  print_endline "";
  print_endline "Run 'wand h <command>' for command-specific help."

let usage_for sub =
  match sub with
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
    print_endline "  --load <file>   Load a .wand file before typechecking (repeatable)";
    print_endline "  --strict        Treat mechanical lint findings as errors";
    print_endline "  --json          Emit lint findings as JSON instead of text";
    print_endline "";
    print_endline "Lint findings are reported as warnings. Rule IDs carry";
    print_endline "their classification: M- rules are mechanical and --strict";
    print_endline "promotes them to errors; H- rules are heuristics and always";
    print_endline "stay warnings."
  | "d" | "doc" ->
    print_endline "Usage: wand d [--load <file>]... <name>";
    print_endline "";
    print_endline "Print the doc string for a name.";
    print_endline "";
    print_endline "Options:";
    print_endline "  --load <file>   Load a .wand file before looking up the name (repeatable)"
  | "fmt" | "format" ->
    print_endline "Usage: wand fmt <file.wand>...";
    print_endline "";
    print_endline "Format one or more .wand files in place (each file is";
    print_endline "overwritten with its formatted contents).";
    print_endline "Comments are preserved; constructs without a dedicated";
    print_endline "formatting rule yet (requires/ensures, handle, $()/$?(), try,";
    print_endline "regex literals) are re-emitted verbatim."
  | "test" ->
    print_endline "Usage: wand test <file.wand>...";
    print_endline "";
    print_endline "Run one or more .wand test files (import Test; test \"label\"";
    print_endline "(fn t -> t.ok/t.eq/t.raises ...)) and report pass/fail.";
    print_endline "Exits nonzero if any test failed or any file errored."
  | "h" | "help" ->
    print_endline "Usage: wand h [command]";
    print_endline "";
    print_endline "Show help for all commands, or detailed help for a specific command."
  | _ ->
    Printf.eprintf "Unknown command: %s\nRun 'wand h' for usage.\n" sub;
    exit 1

let parse_loads args =
  let rec go loads rest = function
    | "--load" :: file :: tail -> go (loads @ [file]) rest tail
    | arg :: tail              -> go loads (rest @ [arg]) tail
    | []                       -> (loads, rest)
  in
  go [] [] args

(* --strict promotes mechanical lints to errors; --json emits findings for a
   tool to read rather than a person. *)
let parse_lint_flags args =
  let strict = ref false and json = ref false in
  let rest = List.filter (fun a ->
    match a with
    | "--strict" -> strict := true; false
    | "--json"   -> json := true; false
    | _ -> true) args
  in
  (!strict, !json, rest)

(* Returns the exit code: lints are warnings unless --strict promotes a
   mechanical one. *)
let report_lints ~strict ~json sess src =
  match Wand.Runner.lint_session sess src with
  | Error _ -> 0   (* the typecheck itself already reported this *)
  | Ok [] -> if json then print_endline "[]"; 0
  | Ok findings ->
    if json then (print_endline (Wand.Lint.to_json findings); 0)
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
      | Error _   -> sess
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
      let (strict, json, rest) = parse_lint_flags rest in
      let (loads, rest') = parse_loads rest in
      (match rest' with
       | [] ->
         Printf.eprintf "Error: expected expression\nRun 'wand h t' for usage.\n"; exit 1
       | [expr] ->
         let sess = load_files ~sources:[expr] loads in
         (match Wand.Runner.typecheck_session sess expr with
          | Error msg -> Printf.eprintf "Error: %s\n" msg; exit 1
          | Ok r      ->
            if not json then Wand.Repl.print_result r;
            let code = report_lints ~strict ~json sess expr in
            if code <> 0 then exit code)
       | _ ->
         Printf.eprintf "Error: too many arguments\nRun 'wand h t' for usage.\n"; exit 1)
    | "d" | "doc" ->
      let (loads, rest') = parse_loads rest in
      (match rest' with
       | [] ->
         Printf.eprintf "Error: expected name\nRun 'wand h d' for usage.\n"; exit 1
       | [name] ->
         let sess = load_files ~sources:[name] loads in
         (match Wand.Runner.lookup_type sess name with
          | Some t -> Printf.printf "%s : %s\n" name t
          | None   -> ());
         (match List.assoc_opt name sess.Wand.Runner.s_docs with
          | Some doc -> print_endline doc
          | None     -> Printf.printf "%s: no doc\n" name)
       | _ ->
         Printf.eprintf "Error: too many arguments\nRun 'wand h d' for usage.\n"; exit 1)
    | "env" ->
      let (loads, rest') = parse_loads rest in
      (* `wand env <module>` needs only that module; bare `wand env` lists
         everything in scope, so it does load them all. *)
      let sess = match rest' with
        | [modname] -> load_files ~sources:[modname] loads
        | _ -> load_files ~sources:[all_stdlib_imports] loads
      in
      (match rest' with
       | [modname] ->
         (match List.assoc_opt modname sess.Wand.Runner.s_type_env with
          | Some (Wand.Typechecker.Namespace members) ->
            let sorted = List.sort (fun (a, _) (b, _) -> String.compare a b) members in
            List.iter (fun (name, scheme) ->
              Printf.printf "%s.%s : %s\n" modname name (Wand.Typechecker.string_of_scheme scheme)
            ) sorted
          | Some _ -> Printf.eprintf "%s is a binding, not a module\n" modname; exit 1
          | None   -> Printf.eprintf "Unknown module '%s'\n" modname; exit 1)
       | _ ->
         let entries = List.sort (fun (a, _) (b, _) -> String.compare a b) sess.Wand.Runner.s_type_env in
         if entries = [] then print_endline "(empty)"
         else List.iter (fun (name, s) ->
           match s with
           | Wand.Typechecker.Namespace _ -> print_endline name
           | _ -> Printf.printf "%s : %s\n" name (Wand.Typechecker.string_of_scheme s)
         ) entries)
    | "fmt" | "format" ->
      (match rest with
       | [] ->
         Printf.eprintf "Error: expected one or more files\nRun 'wand h fmt' for usage.\n"; exit 1
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
              | Wand.Lexer.LexError m ->
                had_error := true; Printf.eprintf "Error: %s: lex error: %s\n" path m
              | Wand.Parser.ParseError m ->
                had_error := true; Printf.eprintf "Error: %s: parse error: %s\n" path m)
         ) paths;
         if !had_error then exit 1)
    | "test" ->
      (match rest with
       | [] ->
         Printf.eprintf "Error: expected one or more files\nRun 'wand h test' for usage.\n"; exit 1
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
      (match Wand.Runner.run_file ~mode path with
       | Ok v    -> if v <> "()" then print_endline v
       | Error e -> Printf.eprintf "Error: %s\n" e; exit 1)
