let history_file =
  match Sys.getenv_opt "HOME" with
  | Some home -> Filename.concat home ".wand_history"
  | None -> ".wand_history"

(* Shared session reference for the completion callback *)
let session_ref : Runner.session ref = ref (Runner.make_session ())

(* ── Multi-line detection ─────────────────────────────────────────────────── *)

let starts_with s prefix =
  let ls = String.length s and lp = String.length prefix in
  ls >= lp && String.sub s 0 lp = prefix

let is_ident_char = function
  | 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' | '!' | '?' | '.' -> true
  | _ -> false

let is_complete src =
  let depth  = ref 0 in
  let in_str = ref false in
  (* A backtick string is the other way to be mid-literal, and it is the one
     that spans lines on purpose. No escapes exist inside one, so any
     backtick ends it. *)
  let in_raw = ref false in
  let escape = ref false in
  String.iter (fun c ->
    if !escape then escape := false
    else if !in_raw then (if c = '`' then in_raw := false)
    else if !in_str then (
      if c = '\\' then escape := true
      else if c = '"' then in_str := false)
    else (match c with
      | '"'       -> in_str := true
      | '`'       -> in_raw := true
      | '(' | '[' -> incr depth
      | ')' | ']' -> decr depth
      | _         -> ())
  ) src;
  if !in_str || !in_raw || !depth > 0 then false
  else
    let s = String.trim src in
    let n = String.length s in
    if n = 0 then true
    else
      let ends_with suf =
        let l = String.length suf in
        n >= l && String.sub s (n - l) l = suf
      in
      (* A keyword only dangles when it is a whole word. `ends_with "with"`
         alone would also fire on `String.starts_with`, leaving a session
         that named the function waiting for a line that is never coming. *)
      let ends_with_kw kw =
        ends_with kw
        && (n = String.length kw || not (is_ident_char s.[n - String.length kw - 1]))
      in
      (* A match's arms are not part of the line that opens it, and the arm
         list has no closing token -- so `match s with` looks finished, and
         so does every arm. Both keep the continuation prompt up, and a
         blank line ends the definition, as it already did elsewhere. *)
      let last_line =
        match String.rindex_opt s '\n' with
        | Some i -> String.trim (String.sub s (i + 1) (n - i - 1))
        | None   -> s
      in
      (* `|` opens an arm; `|>` and `||` are operators continuing a line. *)
      let opens_arm =
        String.length last_line > 0 && last_line.[0] = '|'
        && not (starts_with last_line "|>" || starts_with last_line "||")
      in
      not (ends_with "->" || ends_with "=" || ends_with "|" ||
           ends_with_kw "then" || ends_with_kw "else" || ends_with_kw "in" ||
           ends_with_kw "with" || ends_with "," || opens_arm)

(* ── Result display ───────────────────────────────────────────────────────── *)

let print_result = function
  | Runner.RSilent        -> ()
  | Runner.RBind  (n, t)  -> Printf.printf "%s : %s\n%!" n t
  | Runner.RType  n       -> Printf.printf "type %s\n%!" n
  | Runner.RVal   (v, t)  -> Printf.printf "%s : %s\n%!" v t
  | Runner.RTypeExpr t    -> Printf.printf "%s\n%!" t
  | Runner.RHoles holes   ->
    List.iter (fun t -> Printf.printf "Hole: %s\n%!" t) holes

(* ── Multi-line input ─────────────────────────────────────────────────────── *)

let rec gather_lines acc =
  if is_complete acc then acc
  else
    match LNoise.linenoise "   .. " with
    | None      -> acc
    | Some ""   -> acc
    | Some more -> gather_lines (acc ^ "\n" ^ more)

(* linenoise edits one line and draws a stored newline without returning the
   cursor, so a multi-line entry recalled with Up came back as a staircase
   with its opening characters scrolled off. History holds the definition
   joined into the single line linenoise can actually show and edit.

   Joining has to drop `--` comments: without the newline that ended one,
   it would comment out the rest of the definition. A `--` inside a string
   is not a comment, so the scan tracks quoting. Block comments survive --
   they carry their own terminator. *)
(* Joining changes what a backtick string means -- its newlines are its
   content, and a recalled entry that quietly said something else would be
   worse than no entry. Such a definition is left out of history rather than
   flattened into a lie. *)
let can_flatten src =
  not (String.contains src '\n' && String.contains src '`')

let flatten_for_history src =
  if not (String.contains src '\n') then src
  else
    let strip_line_comment line =
      let n = String.length line in
      let in_str = ref false and escape = ref false in
      let cut = ref n and i = ref 0 in
      while !i < n && !cut = n do
        let c = line.[!i] in
        if !escape then escape := false
        else if !in_str then (
          if c = '\\' then escape := true
          else if c = '"' then in_str := false)
        else if c = '"' then in_str := true
        else if c = '-' && !i + 1 < n && line.[!i + 1] = '-' then cut := !i;
        incr i
      done;
      String.sub line 0 !cut
    in
    String.split_on_char '\n' src
    |> List.map (fun l -> String.trim (strip_line_comment l))
    |> List.filter (fun l -> l <> "")
    |> String.concat " "

(* ── Tab completion ───────────────────────────────────────────────────────── *)

let special_commands =
  [":type"; ":t"; ":doc"; ":d"; ":edit"; ":e";
   ":load"; ":l"; ":reload"; ":r"; ":env"; ":v"; ":clear"; ":c";
   ":reset"; ":s"; ":exit"; ":x"; ":help"; ":h"]

let builtin_names = ["print"; "println"; "Ok"; "Error"]

let ident_arg_commands = [":type "; ":t "; ":doc "; ":d "; ":env "; ":v "]

let complete_ident_arg line prefix_end completions =
  let n = String.length line in
  let i = ref (n - 1) in
  while !i >= prefix_end && is_ident_char line.[!i] do decr i done;
  let prefix_start = !i + 1 in
  let prefix = String.sub line prefix_start (n - prefix_start) in
  let before  = String.sub line 0 prefix_start in
  let sess    = !session_ref in
  match String.split_on_char '.' prefix with
  | [ns; member_prefix] ->
    (match List.assoc_opt ns sess.s_type_env with
     | Some (Typechecker.Namespace members) ->
       List.iter (fun (name, _) ->
         if starts_with name member_prefix then
           LNoise.add_completion completions (before ^ ns ^ "." ^ name)
       ) members
     | _ -> ())
  | [ident_prefix] ->
    let all_names =
      List.filter_map (fun (name, _) ->
        if starts_with name ident_prefix then Some name else None
      ) sess.s_type_env
      @ List.filter (fun n -> starts_with n ident_prefix) builtin_names
    in
    List.iter (fun name ->
      LNoise.add_completion completions (before ^ name)
    ) all_names
  | _ -> ()

let complete_line line completions =
  let n = String.length line in
  if n > 0 && line.[0] = ':' then begin
    (* Check if we're completing an argument to a command that takes an ident *)
    let cmd_match = List.find_opt (fun cmd -> starts_with line cmd) ident_arg_commands in
    match cmd_match with
    | Some cmd -> complete_ident_arg line (String.length cmd) completions
    | None ->
      (* Command name completion *)
      List.iter (fun cmd ->
        if starts_with cmd line then LNoise.add_completion completions cmd
      ) special_commands
  end else begin
    complete_ident_arg line 0 completions
  end

(* ── Editor integration ───────────────────────────────────────────────────── *)

let find_editor () =
  match Sys.getenv_opt "EDITOR" with
  | Some e -> e
  | None -> match Sys.getenv_opt "VISUAL" with
    | Some e -> e
    | None -> "vi"

let edit_in_editor (sess : Runner.session) content =
  let tmp = Filename.temp_file "wand_edit_" ".wand" in
  Fun.protect ~finally:(fun () -> (try Sys.remove tmp with Sys_error _ -> ())) (fun () ->
    Out_channel.with_open_text tmp (fun oc -> output_string oc content);
    let editor = find_editor () in
    let exit_code = Sys.command (Printf.sprintf "%s %s" editor (Filename.quote tmp)) in
    if exit_code <> 0 then (
      Printf.printf "Editor exited with code %d — discarding changes.\n%!" exit_code;
      sess)
    else
      let src = In_channel.with_open_text tmp In_channel.input_all in
      let src = String.trim src in
      if src = "" || src = String.trim content then (
        print_endline "No changes."; sess)
      else
        match Runner.run_session sess src with
        | Error msg -> Printf.printf "Error: %s\n(changes discarded)\n%!" msg; sess
        | Ok (new_sess, result) -> print_result result; new_sess)

(* ── Special commands and main loop (mutually recursive) ─────────────────── *)

let load_file (sess : Runner.session) path =
  let full = if Filename.is_relative path
             then Filename.concat sess.s_base_dir path
             else path in
  match (try Ok (In_channel.with_open_text full In_channel.input_all)
         with Sys_error m -> Error m) with
  | Error m ->
    Printf.eprintf "Error: cannot load '%s': %s\n%!" path m; sess
  | Ok src ->
    match Runner.run_session { sess with s_last_load = Some full } src with
    | Error msg ->
      Printf.eprintf "Error: %s\n%!" msg; sess
    | Ok (new_sess, _) ->
      Printf.printf "loaded %s\n%!" (Filename.basename full);
      new_sess

let rec handle_command (sess : Runner.session) (line : string) : Runner.session =
  let parts = String.split_on_char ' ' (String.trim line) in
  let cmd   = List.nth parts 0 in
  let rest  = String.trim (String.sub line (String.length cmd)
                             (String.length line - String.length cmd)) in
  match cmd with
  | ":x" | ":exit" ->
    ignore (LNoise.history_save ~filename:history_file);
    exit 0
  | ":h" | ":help" ->
    print_endline "Commands:";
    print_endline "  :c           (:clear)  — clear the screen";
    print_endline "  :d <name>    (:doc)    — show doc string";
    print_endline "  :e [name]    (:edit)   — open definition in $EDITOR";
    print_endline "  :l <path>    (:load)   — load a .wand file into session";
    print_endline "  :r           (:reload) — reload last loaded file";
    print_endline "  :s           (:reset)  — clear the screen and all session bindings";
    print_endline "  :t <expr>    (:type)   — show type without evaluating";
    print_endline "  :v [module]  (:env)    — list bindings and modules; :v List shows List members";
    print_endline "  :x           (:exit)   — exit interactive mode";
    flush stdout;
    sess
  | ":t" | ":type" ->
    if rest = "" then (print_endline "Usage: :t <expr>"; sess)
    else begin
      (match Runner.typecheck_session sess rest with
       | Error msg -> Printf.printf "Error: %s\n%!" msg
       | Ok r      -> print_result r);
      sess
    end
  | ":d" | ":doc" ->
    if rest = "" then (print_endline "Usage: :d <name>"; sess)
    else begin
      (match Runner.lookup_type sess rest with
       | Some t -> Printf.printf "%s : %s\n" rest t
       | None   -> ());
      (match List.assoc_opt rest sess.s_docs with
       | Some doc -> Printf.printf "%s\n%!" doc
       | None     ->
         if Runner.lookup_type sess rest = None then
           Printf.printf "%s: does not exist\n%!" rest
         else
           Printf.printf "%s: no doc\n%!" rest);
      sess
    end
  | ":e" | ":edit" ->
    let content =
      if rest = "" then ""
      else
        let all_srcs = List.filter_map (fun (name, src) ->
          if name = rest then Some src else None) sess.s_sources in
        match all_srcs with
        | [] ->
          (match List.assoc_opt rest sess.s_type_env with
           | Some _ -> Printf.sprintf "let %s = " rest
           | None   -> "")
        | srcs ->
          let seen = Hashtbl.create 4 in
          let unique = List.filter (fun s ->
            if Hashtbl.mem seen s then false
            else (Hashtbl.add seen s (); true)) srcs in
          String.concat "\n" (List.rev unique)
    in
    edit_in_editor sess content
  | ":l" | ":load" ->
    if rest = "" then (print_endline "Usage: :l <path>"; sess)
    else load_file sess rest
  | ":r" | ":reload" ->
    (match sess.s_last_load with
     | None      -> print_endline "No file loaded yet."; sess
     | Some path -> load_file sess path)
  | ":s" | ":reset" ->
    LNoise.clear_screen ();
    print_endline "Session reset.";
    let prelude = "import List\nimport String\nimport Path\nimport FS\nimport IO\n\
                   import Duration\nimport Env\nimport Regex" in
    let fresh = Runner.make_session ~base_dir:sess.s_base_dir () in
    (match Runner.run_session fresh prelude with
     | Ok (s, _) -> s
     | Error _   -> fresh)
  | ":c" | ":clear" ->
    LNoise.clear_screen (); sess
  | ":v" | ":env" ->
    if rest <> "" then begin
      (* :env ModuleName — show members of that namespace *)
      match List.assoc_opt rest sess.s_type_env with
      | Some (Typechecker.Namespace members) ->
        let sorted = List.sort (fun (a, _) (b, _) -> String.compare a b) members in
        List.iter (fun (name, scheme) ->
          Printf.printf "%s.%s : %s\n" rest name (Typechecker.string_of_scheme scheme)
        ) sorted
      | Some _ ->
        Printf.printf "%s is a binding, not a module\n" rest
      | None ->
        Printf.printf "Unknown module '%s'\n" rest
    end else begin
      (* :env — show loaded modules and user bindings *)
      let entries = List.sort (fun (a, _) (b, _) -> String.compare a b) sess.s_type_env in
      if entries = [] then print_endline "(empty)"
      else List.iter (fun (name, s) ->
        match s with
        | Typechecker.Namespace _ -> print_endline name
        | _ -> Printf.printf "%s : %s\n" name (Typechecker.string_of_scheme s)
      ) entries
    end;
    flush stdout;
    sess
  | _ ->
    Printf.printf "Unknown command '%s' — type :h for a list\n%!" cmd;
    sess

and loop (sess : Runner.session) =
  session_ref := sess;
  match LNoise.linenoise ">> " with
  | None ->
    print_newline ();
    ignore (LNoise.history_save ~filename:history_file)
  | Some line ->
    let line = String.trim line in
    if line = "" then loop sess
    else begin
      if line.[0] = ':' then begin
        ignore (LNoise.history_add line);
        loop (handle_command sess line)
      end
      else begin
        let src = gather_lines line in
        (* Added once the definition is whole. Adding the opening line first
           and each accumulation after it left four entries for a four-line
           definition, three of them prefixes of the fourth. *)
        if can_flatten src then
          ignore (LNoise.history_add (flatten_for_history src));
        (* Ctrl-C abandons what is running and gives the prompt back, rather
           than ending the session: at a prompt, stopping the thing you just
           typed is what you meant, not stopping the session you are in the
           middle of. The session carries on from the bindings it already
           had -- the interrupted expression contributed none. *)
        match Runner.run_session sess src with
        | Error msg ->
          Printf.printf "Error: %s\n%!" msg;
          loop sess
        | Ok (new_sess, result) ->
          print_result result;
          loop new_sess
        | exception Evaluator.Interrupted _ ->
          Runner.rearm_signal_handlers ();
          Printf.printf "\ninterrupted\n%!";
          loop sess
      end
    end

let stdlib_prelude =
  String.concat "\n"
    (List.map (fun n -> "import " ^ n) Typechecker.stdlib_module_names)

let run ?(base_dir = Sys.getcwd ()) ?(loads = []) () =
  (* Flushed, because linenoise writes the prompt with its own `write` rather
     than through this buffer, and an unflushed banner lands after it. *)
  Printf.printf "wand v%s interactive - :h for commands, :x to exit\n%!"
    Version.value;
  LNoise.set_completion_callback complete_line;
  ignore (LNoise.history_set ~max_length:1000);
  ignore (LNoise.history_load ~filename:history_file);
  let sess = Runner.make_session ~base_dir () in
  let sess = match Runner.run_session sess stdlib_prelude with
    | Ok (s, _) -> s
    | Error msg ->
      (* Without the prelude every stdlib name in the session is unbound, so
         say why rather than letting each use report its own confusion. *)
      Printf.printf "warning: standard library not loaded: %s\n%!" msg;
      sess
  in
  let sess = List.fold_left load_file sess loads in
  Runner.install_signal_handlers ();
  loop sess
