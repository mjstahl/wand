open Wand

let history_file =
  match Sys.getenv_opt "HOME" with
  | Some home -> Filename.concat home ".wand_history"
  | None -> ".wand_history"

(* Shared session reference for the completion callback *)
let session_ref : Runner.session ref = ref (Runner.make_session ())

(* ── Multi-line detection ─────────────────────────────────────────────────── *)

let is_complete src =
  let depth  = ref 0 in
  let in_str = ref false in
  let escape = ref false in
  String.iter (fun c ->
    if !escape then escape := false
    else if !in_str then (
      if c = '\\' then escape := true
      else if c = '"' then in_str := false)
    else (match c with
      | '"'       -> in_str := true
      | '(' | '[' -> incr depth
      | ')' | ']' -> decr depth
      | _         -> ())
  ) src;
  if !in_str || !depth > 0 then false
  else
    let s = String.trim src in
    let n = String.length s in
    if n = 0 then true
    else
      let ends_with suf =
        let l = String.length suf in
        n >= l && String.sub s (n - l) l = suf
      in
      not (ends_with "->" || ends_with "=" || ends_with "|" ||
           ends_with "then" || ends_with "else" || ends_with "in" ||
           ends_with ",")

(* ── Result display ───────────────────────────────────────────────────────── *)

let print_result = function
  | Runner.RSilent        -> ()
  | Runner.RBind  (n, t)  -> Printf.printf "%s : %s\n%!" n t
  | Runner.RType  n       -> Printf.printf "type %s\n%!" n
  | Runner.RVal   (v, t)  -> Printf.printf "%s : %s\n%!" v t
  | Runner.RTypeExpr t    -> Printf.printf "%s\n%!" t

(* ── Multi-line input ─────────────────────────────────────────────────────── *)

let rec gather_lines acc =
  if is_complete acc then acc
  else
    match LNoise.linenoise "   .. " with
    | None      -> acc
    | Some ""   -> acc
    | Some more ->
      let combined = acc ^ "\n" ^ more in
      ignore (LNoise.history_add combined);
      gather_lines combined

(* ── Tab completion ───────────────────────────────────────────────────────── *)

let special_commands =
  [":type"; ":t"; ":doc"; ":d"; ":edit"; ":e";
   ":load"; ":l"; ":reload"; ":r"; ":env"; ":clear"; ":reset"; ":quit"; ":q"; ":help"; ":h"]

let builtin_names = ["print"; "println"; "exit"; "Ok"; "Error"]

let is_ident_char = function
  | 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' | '!' | '?' | '.' -> true
  | _ -> false

let starts_with s prefix =
  let ls = String.length s and lp = String.length prefix in
  ls >= lp && String.sub s 0 lp = prefix

let complete_line line completions =
  let n = String.length line in
  if n > 0 && line.[0] = ':' then
    (* Command completion *)
    List.iter (fun cmd ->
      if starts_with cmd line then LNoise.add_completion completions cmd
    ) special_commands
  else begin
    (* Find the token being completed by walking back over ident chars *)
    let i = ref (n - 1) in
    while !i >= 0 && is_ident_char line.[!i] do decr i done;
    let prefix_start = !i + 1 in
    let prefix = String.sub line prefix_start (n - prefix_start) in
    let before  = String.sub line 0 prefix_start in
    let sess    = !session_ref in
    match String.split_on_char '.' prefix with
    | [ns; member_prefix] ->
      (* ModuleName.prefix → complete module members *)
      (match List.assoc_opt ns sess.s_type_env with
       | Some (Typechecker.Namespace members) ->
         List.iter (fun (name, _) ->
           if starts_with name member_prefix then
             LNoise.add_completion completions (before ^ ns ^ "." ^ name)
         ) members
       | _ -> ())
    | [ident_prefix] ->
      (* Plain identifier → complete from all names in scope + builtins *)
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
  | ":q" | ":quit" ->
    ignore (LNoise.history_save ~filename:history_file);
    exit 0
  | ":h" | ":help" ->
    print_endline "Special commands:";
    print_endline "  :type <expr>   (:t)  — show type without evaluating";
    print_endline "  :doc  <name>   (:d)  — show doc string";
    print_endline "  :edit [name]   (:e)  — open definition in $EDITOR";
    print_endline "  :load <path>   (:l)  — load a .wand file into session";
    print_endline "  :reload        (:r)  — reload last loaded file";
    print_endline "  :env                 — list bindings in scope";
    print_endline "  :clear               — clear the screen";
    print_endline "  :reset               — clear all session bindings";
    print_endline "  :quit          (:q)  — exit";
    sess
  | ":t" | ":type" ->
    if rest = "" then (print_endline "Usage: :type <expr>"; sess)
    else begin
      (match Runner.typecheck_session sess rest with
       | Error msg -> Printf.printf "Error: %s\n%!" msg
       | Ok r      -> print_result r);
      sess
    end
  | ":d" | ":doc" ->
    if rest = "" then (print_endline "Usage: :doc <name>"; sess)
    else (Printf.printf "%s: no doc\n%!" rest; sess)
  | ":e" | ":edit" ->
    let content =
      if rest = "" then ""
      else
        match List.assoc_opt rest sess.s_sources with
        | Some src -> src
        | None ->
          (match List.assoc_opt rest sess.s_type_env with
           | Some _ -> Printf.sprintf "let %s = " rest
           | None   -> "")
    in
    edit_in_editor sess content
  | ":l" | ":load" ->
    if rest = "" then (print_endline "Usage: :load <path>"; sess)
    else load_file sess rest
  | ":r" | ":reload" ->
    (match sess.s_last_load with
     | None      -> print_endline "No file loaded yet."; sess
     | Some path -> load_file sess path)
  | ":reset" ->
    print_endline "Session reset.";
    let prelude = "import List\nimport String\nimport Path\nimport FS\nimport IO\n\
                   import Duration\nimport Process\nimport Env" in
    let fresh = Runner.make_session ~base_dir:sess.s_base_dir () in
    (match Runner.run_session fresh prelude with
     | Ok (s, _) -> s
     | Error _   -> fresh)
  | ":clear" ->
    LNoise.clear_screen (); sess
  | ":env" ->
    let entries = sess.s_type_env |> List.rev |> List.filter (fun (_, s) ->
      match s with Typechecker.Namespace _ -> false | _ -> true) in
    if entries = [] then print_endline "(no bindings)"
    else List.iter (fun (name, scheme) ->
      Printf.printf "  %s : %s\n" name (Typechecker.string_of_scheme scheme)
    ) entries;
    sess
  | _ ->
    Printf.printf "Unknown command '%s' — type :help for a list\n%!" cmd;
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
      ignore (LNoise.history_add line);
      if line.[0] = ':' then
        loop (handle_command sess line)
      else begin
        let src = gather_lines line in
        match Runner.run_session sess src with
        | Error msg ->
          Printf.printf "Error: %s\n%!" msg;
          loop sess
        | Ok (new_sess, result) ->
          print_result result;
          loop new_sess
      end
    end

let stdlib_prelude =
  "import List\nimport String\nimport Path\nimport FS\nimport IO\n\
   import Duration\nimport Process\nimport Env"

let run ?(base_dir = Sys.getcwd ()) ?(loads = []) () =
  print_endline "wand interactive — :help for commands, :quit to exit";
  LNoise.set_completion_callback complete_line;
  ignore (LNoise.history_set ~max_length:1000);
  ignore (LNoise.history_load ~filename:history_file);
  let sess = Runner.make_session ~base_dir () in
  let sess = match Runner.run_session sess stdlib_prelude with
    | Ok (s, _) -> s
    | Error _   -> sess
  in
  let sess = List.fold_left load_file sess loads in
  loop sess
