let usage () =
  print_endline "wand — a typed language for human/AI pairing";
  print_endline "";
  print_endline "Usage: wand <command> [options] [args]";
  print_endline "       wand <file.wand> [args]";
  print_endline "";
  print_endline "Commands:";
  print_endline "  i, interactive   Start an interactive session";
  print_endline "  e, eval <expr>   Evaluate an expression and exit";
  print_endline "  t, type <expr>   Typecheck an expression without evaluating";
  print_endline "  d, doc  <name>   Print the doc string for a name";
  print_endline "  env              List all names and modules in scope";
  print_endline "  h, help [cmd]    Show this help, or help for a command";
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
    print_endline "  --load <file>   Load a .wand file before typechecking (repeatable)"
  | "d" | "doc" ->
    print_endline "Usage: wand d [--load <file>]... <name>";
    print_endline "";
    print_endline "Print the doc string for a name.";
    print_endline "";
    print_endline "Options:";
    print_endline "  --load <file>   Load a .wand file before looking up the name (repeatable)"
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

let stdlib_prelude =
  "import List\nimport String\nimport Path\nimport FS\nimport IO\n\
   import Duration\nimport Env\nimport Map\nimport Regex"

let load_files loads =
  let sess = Wand.Runner.make_session () in
  let sess = match Wand.Runner.run_session sess stdlib_prelude with
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
         let sess = load_files loads in
         (match Wand.Runner.run_session sess expr with
          | Error msg -> Printf.eprintf "Error: %s\n" msg; exit 1
          | Ok (_, r) -> Wand.Repl.print_result r)
       | _ ->
         Printf.eprintf "Error: too many arguments\nRun 'wand h e' for usage.\n"; exit 1)
    | "t" | "type" ->
      let (loads, rest') = parse_loads rest in
      (match rest' with
       | [] ->
         Printf.eprintf "Error: expected expression\nRun 'wand h t' for usage.\n"; exit 1
       | [expr] ->
         let sess = load_files loads in
         (match Wand.Runner.typecheck_session sess expr with
          | Error msg -> Printf.eprintf "Error: %s\n" msg; exit 1
          | Ok r      -> Wand.Repl.print_result r)
       | _ ->
         Printf.eprintf "Error: too many arguments\nRun 'wand h t' for usage.\n"; exit 1)
    | "d" | "doc" ->
      let (loads, rest') = parse_loads rest in
      (match rest' with
       | [] ->
         Printf.eprintf "Error: expected name\nRun 'wand h d' for usage.\n"; exit 1
       | [name] ->
         let sess = load_files loads in
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
      let sess = load_files loads in
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
    | path ->
      (* Legacy: wand <file.wand> [args] *)
      Wand.Evaluator.exe_args_ref := rest;
      (match Wand.Runner.run_file path with
       | Ok v    -> if v <> "()" then print_endline v
       | Error e -> Printf.eprintf "Error: %s\n" e; exit 1)
