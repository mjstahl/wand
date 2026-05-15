open Evaluator

(* ── Default effect handlers ──────────────────────────────────────────────── *)

let exec_command cmd =
  let ic = Unix.open_process_in cmd in
  let buf = Buffer.create 64 in
  (try while true do Buffer.add_channel buf ic 1 done
   with End_of_file -> ());
  let status = Unix.close_process_in ic in
  let output = Buffer.contents buf in
  let output =
    let n = String.length output in
    let i = ref n in
    while !i > 0 && output.[!i - 1] = '\n' do decr i done;
    String.sub output 0 !i
  in
  match status with
  | Unix.WEXITED 0   -> output
  | Unix.WEXITED n   -> raise (EvalError (Printf.sprintf "command exited with code %d: %s" n cmd))
  | Unix.WSIGNALED n -> raise (EvalError (Printf.sprintf "command killed by signal %d: %s" n cmd))
  | Unix.WSTOPPED  n -> raise (EvalError (Printf.sprintf "command stopped by signal %d: %s" n cmd))

let exec_command_quiet cmd =
  let ic = Unix.open_process_in cmd in
  (try while true do ignore (input_char ic) done with End_of_file -> ());
  match Unix.close_process_in ic with
  | Unix.WEXITED 0   -> ()
  | Unix.WEXITED n   -> raise (EvalError (Printf.sprintf "command exited with code %d: %s" n cmd))
  | Unix.WSIGNALED n -> raise (EvalError (Printf.sprintf "command killed by signal %d: %s" n cmd))
  | Unix.WSTOPPED  n -> raise (EvalError (Printf.sprintf "command stopped by signal %d: %s" n cmd))

let exec_command_exit_code cmd =
  let ic = Unix.open_process_in cmd in
  (try while true do ignore (input_char ic) done with End_of_file -> ());
  match Unix.close_process_in ic with
  | Unix.WEXITED n   -> n
  | Unix.WSIGNALED _ -> 128
  | Unix.WSTOPPED  _ -> 128

let run_with_default_handler (thunk : unit -> value) : value =
  Effect.Deep.match_with thunk ()
    { Effect.Deep.
        retc = (fun v -> v);
        exnc = raise;
        effc = fun (type a) (eff : a Effect.t) ->
          match eff with
          | WandEffect ("print", v) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              print_string (show_value v);
              Effect.Deep.continue k VUnit)
          | WandEffect ("println", v) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              print_endline (show_value v);
              Effect.Deep.continue k VUnit)
          | WandEffect ("process_run", VString cmd) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match (try Ok (exec_command cmd) with EvalError m -> Error m) with
              | Ok s    -> Effect.Deep.continue    k (VString s)
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect ("process_run_quiet", VString cmd) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match (try exec_command_quiet cmd; Ok () with EvalError m -> Error m) with
              | Ok ()   -> Effect.Deep.continue    k VUnit
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect ("process_exit_code", VString cmd) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              Effect.Deep.continue k (VInt (exec_command_exit_code cmd)))
          | WandEffect ("read_file", VString path) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match (try Ok (In_channel.with_open_text path In_channel.input_all)
                     with Sys_error m -> Error ("read_file: " ^ m)) with
              | Ok s    -> Effect.Deep.continue    k (VString s)
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect ("write_file", VTuple [VString path; VString content]) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match (try Out_channel.with_open_text path
                           (fun oc -> Out_channel.output_string oc content); Ok ()
                     with Sys_error m -> Error ("write_file: " ^ m)) with
              | Ok ()   -> Effect.Deep.continue    k VUnit
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect ("fs_mkdir", VString path) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match (try Unix.mkdir path 0o755; Ok ()
                     with Unix.Unix_error (e, _, _) -> Error ("mkdir: " ^ Unix.error_message e)) with
              | Ok ()   -> Effect.Deep.continue    k VUnit
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect ("fs_mkdir_p", VPath path) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              let rec mkdir_p p =
                if Sys.file_exists p then ()
                else begin mkdir_p (Filename.dirname p); Unix.mkdir p 0o755 end
              in
              match (try mkdir_p path; Ok ()
                     with Unix.Unix_error (e, _, _) -> Error ("mkdir_p: " ^ Unix.error_message e)) with
              | Ok ()   -> Effect.Deep.continue    k VUnit
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect ("fs_ls", VPath path) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match (try
                       let entries = Sys.readdir path in
                       Array.sort String.compare entries;
                       Ok (Array.to_list (Array.map (fun s ->
                         VPath (Filename.concat path s)) entries))
                     with Sys_error m -> Error ("ls: " ^ m)) with
              | Ok vs   -> Effect.Deep.continue    k (VList vs)
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect ("fs_append", VTuple [VPath path; VString content]) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match (try Out_channel.with_open_gen
                           [Open_wronly; Open_creat; Open_append] 0o644 path
                           (fun oc -> Out_channel.output_string oc content); Ok ()
                     with Sys_error m -> Error ("append: " ^ m)) with
              | Ok ()   -> Effect.Deep.continue    k VUnit
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect ("fs_create", VPath path) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match (try Out_channel.with_open_gen
                           [Open_wronly; Open_creat; Open_trunc] 0o644 path
                           (fun _ -> ()); Ok ()
                     with Sys_error m -> Error ("create_file: " ^ m)) with
              | Ok ()   -> Effect.Deep.continue    k VUnit
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect ("fs_rename", VTuple [VPath old_; VPath new_]) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match (try Unix.rename old_ new_; Ok ()
                     with Unix.Unix_error (e, _, _) ->
                       Error ("rename: " ^ Unix.error_message e)) with
              | Ok ()   -> Effect.Deep.continue    k VUnit
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect ("fs_copy", VTuple [VPath src; VPath dst]) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match (try
                       let content = In_channel.with_open_bin src In_channel.input_all in
                       Out_channel.with_open_bin dst
                         (fun oc -> Out_channel.output_string oc content);
                       Ok ()
                     with Sys_error m -> Error ("copy: " ^ m)) with
              | Ok ()   -> Effect.Deep.continue    k VUnit
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect ("fs_cd", VPath path) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match (try Unix.chdir path; Ok ()
                     with Unix.Unix_error (e, _, _) ->
                       Error ("cd: " ^ Unix.error_message e)) with
              | Ok ()   -> Effect.Deep.continue    k VUnit
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect ("fs_remove", VPath path) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              let rm () =
                if Sys.file_exists path && Sys.is_directory path
                then Unix.rmdir path
                else Sys.remove path
              in
              match (try rm (); Ok ()
                     with Sys_error m -> Error ("remove: " ^ m)
                        | Unix.Unix_error (e, _, _) -> Error ("remove: " ^ Unix.error_message e)) with
              | Ok ()   -> Effect.Deep.continue    k VUnit
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect (("io_print_err" | "print_err"), v) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              output_string stderr (show_value v);
              Effect.Deep.continue k VUnit)
          | WandEffect (("io_println_err" | "println_err"), v) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              output_string stderr (show_value v ^ "\n");
              Effect.Deep.continue k VUnit)
          | WandEffect (("io_read_line" | "read_line"), VUnit) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match (try Ok (input_line stdin) with End_of_file -> Error "end of input") with
              | Ok s    -> Effect.Deep.continue    k (VString s)
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect ("io_read_all", VUnit) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              Effect.Deep.continue k (VString (In_channel.input_all stdin)))
          | WandEffect ("io_flush", VUnit) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              flush stdout;
              Effect.Deep.continue k VUnit)
          | _ -> None
    }

(* ── Import resolution ────────────────────────────────────────────────────── *)

let add_ext p = if Filename.check_suffix p ".wand" then p else p ^ ".wand"

let find_stdlib_dir () =
  match Sys.getenv_opt "WAND_STDLIB" with
  | Some dir -> dir
  | None ->
    (* Walk up from CWD until we find a stdlib/ directory *)
    let rec ascend dir =
      let candidate = Filename.concat dir "stdlib" in
      if Sys.file_exists candidate then candidate
      else
        let parent = Filename.dirname dir in
        if parent = dir then Filename.concat (Sys.getcwd ()) "stdlib"
        else ascend parent
    in
    ascend (Sys.getcwd ())

let resolve_stdlib name =
  let stdlib_dir = find_stdlib_dir () in
  let exact = Filename.concat stdlib_dir (name ^ ".wand") in
  if Sys.file_exists exact then exact
  else
    let lower = Filename.concat stdlib_dir (String.lowercase_ascii name ^ ".wand") in
    if Sys.file_exists lower then lower
    else exact

let resolve_import base_dir = function
  | Ast.StdlibModule name -> resolve_stdlib name
  | Ast.UserPath path ->
    if Filename.is_relative path
    then Filename.concat base_dir (add_ext path)
    else add_ext path

let namespace_name_of = function
  | Ast.StdlibModule name -> name
  | Ast.UserPath path ->
    let base = Filename.basename (Filename.remove_extension path) in
    if String.length base = 0 then "Module"
    else String.make 1 (Char.uppercase_ascii base.[0]) ^ String.sub base 1 (String.length base - 1)

type import_env = {
  tenv     : (string * Ast.type_def) list;
  type_env : Typechecker.env;
  eval_env : env;
}

let empty_import_env = { tenv = []; type_env = []; eval_env = [] }

let merge_import_env a b = {
  tenv     = b.tenv @ a.tenv;
  type_env = b.type_env @ a.type_env;
  eval_env = b.eval_env @ a.eval_env;
}

let local_tenv_of prog =
  List.filter_map (function
    | Ast.TLType (Ast.Variants (n, _) as tdef) -> Some (n, tdef)
    | _ -> None) prog.Ast.items

(* Evaluate a single top-level item; imports already merged into env *)
let run_item env item =
  match item with
  | Ast.TLLet (name, [], body) ->
    (name, eval env body) :: env
  | Ast.TLLet (name, params, body) ->
    (name, VFix (name, env, params, body)) :: env
  | Ast.TLImport _ -> env  (* already loaded by load_imports_for *)
  | Ast.TLType (Ast.Variants (_, ctors)) ->
    List.fold_left (fun env ctor ->
      let field_names = List.map fst ctor.Ast.fields in
      Hashtbl.replace Evaluator.constr_fields ctor.Ast.name field_names;
      let v = match ctor.Ast.fields with
        | [] -> VConstr (ctor.Ast.name, [])
        | fs -> VPartialConstr (ctor.Ast.name, List.length fs, [])
      in
      (ctor.Ast.name, v) :: env
    ) env ctors
  | Ast.TLExpr _ -> env

(* ── Module loading ───────────────────────────────────────────────────────── *)

type module_result = import_env * (string * Typechecker.scheme) list * env

(* Load imports for a program.
   `cache` maps path -> result so each module is loaded once per run_program.
   `loading` detects import cycles. *)
let rec load_imports_for ~base_dir ~cache ~loading prog =
  List.fold_left (fun acc item ->
    match item with
    | Ast.TLImport kind ->
      let full = resolve_import base_dir kind in
      let ns_name = namespace_name_of kind in
      let (modul_import, own_type, own_eval) =
        match Hashtbl.find_opt cache full with
        | Some cached -> cached
        | None ->
          if List.mem full !loading then
            failwith ("import cycle detected: " ^ full)
          else
            load_module full ~cache ~loading
      in
      let ns_type_entry = (ns_name, Typechecker.Namespace own_type) in
      let ns_eval_entry = (ns_name, VRecord own_eval) in
      { tenv     = modul_import.tenv @ acc.tenv;
        type_env = ns_type_entry :: modul_import.type_env @ acc.type_env;
        eval_env = ns_eval_entry :: modul_import.eval_env @ acc.eval_env }
    | _ -> acc
  ) empty_import_env prog.Ast.items

and load_module path ~cache ~loading =
  let src =
    try In_channel.with_open_text path In_channel.input_all
    with Sys_error msg ->
      failwith ("cannot import '" ^ path ^ "': " ^ msg)
  in
  let tokens =
    try Lexer.tokenize src
    with Lexer.LexError msg ->
      failwith ("lex error in '" ^ path ^ "': " ^ msg)
  in
  let prog =
    try Parser.parse_program tokens
    with Parser.ParseError msg ->
      failwith ("parse error in '" ^ path ^ "': " ^ msg)
  in
  let base_dir = Filename.dirname path in
  loading := path :: !loading;
  let imported = load_imports_for ~base_dir ~cache ~loading prog in
  let result =
    (match Typechecker.infer_program_env_with_own
             ~init_tenv:imported.tenv ~init_env:imported.type_env prog with
     | Error msg -> failwith ("type error: " ^ msg)
     | Ok (type_env, own_type) ->
       let base = stdlib_eval_env @ imported.eval_env in
       let full_eval = List.fold_left run_item base prog.Ast.items in
       let n_own = List.length full_eval - List.length base in
       let own_eval = List.filteri (fun i _ -> i < n_own) full_eval in
       let full_import = { tenv     = local_tenv_of prog @ imported.tenv;
                           type_env;
                           eval_env = full_eval } in
       (full_import, own_type, own_eval))
  in
  Hashtbl.replace cache path result;
  loading := List.filter (fun p -> p <> path) !loading;
  result

(* ── Run a parsed program ─────────────────────────────────────────────────── *)

let run_program ~base_dir prog =
  let cache = Hashtbl.create 8 in
  let loading = ref [] in
  let imp = load_imports_for ~base_dir ~cache ~loading prog in
  (match Typechecker.infer_program_env ~init_tenv:imp.tenv ~init_env:imp.type_env prog with
   | Error msg -> Error ("type error: " ^ msg)
   | Ok _ ->
     let result = run_with_default_handler (fun () ->
       let (_, last) = List.fold_left (fun (env, last) item ->
         match item with
         | Ast.TLExpr e -> (env, eval env e)
         | _            -> (run_item env item, last)
       ) (base_eval_env @ imp.eval_env, VUnit) prog.Ast.items
       in last
     ) in
     Ok (show_value result))

(* ── Public API ───────────────────────────────────────────────────────────── *)

let run_string src =
  try
    let tokens = Lexer.tokenize src in
    let prog   = Parser.parse_program tokens in
    run_program ~base_dir:(Sys.getcwd ()) prog
  with
  | Lexer.LexError msg    -> Error ("lex error: " ^ msg)
  | Parser.ParseError msg -> Error ("parse error: " ^ msg)
  | EvalError msg         -> Error ("eval error: " ^ msg)
  | Failure msg           -> Error (msg)

let run_file path =
  let full =
    if Filename.is_relative path
    then Filename.concat (Sys.getcwd ()) (add_ext path)
    else add_ext path
  in
  try
    let src      = In_channel.with_open_text full In_channel.input_all in
    let tokens   = Lexer.tokenize src in
    let prog     = Parser.parse_program tokens in
    let base_dir = Filename.dirname full in
    run_program ~base_dir prog
  with
  | Sys_error msg         -> Error ("cannot open file: " ^ msg)
  | Lexer.LexError msg    -> Error ("lex error: " ^ msg)
  | Parser.ParseError msg -> Error ("parse error: " ^ msg)
  | EvalError msg         -> Error ("eval error: " ^ msg)
  | Failure msg           -> Error (msg)
