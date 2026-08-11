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

let read_all ic =
  let buf = Buffer.create 64 in
  (try while true do Buffer.add_channel buf ic 1 done with End_of_file -> ());
  Buffer.contents buf

let strip_trailing_newline s =
  let n = String.length s in
  let i = ref n in
  while !i > 0 && s.[!i - 1] = '\n' do decr i done;
  String.sub s 0 !i

let exec_command_stdin cmd stdin =
  let (ic, oc, ec) = Unix.open_process_full ("sh -c " ^ Filename.quote cmd) (Unix.environment ()) in
  output_string oc stdin; close_out oc;
  let stdout = strip_trailing_newline (read_all ic) in
  let _stderr = read_all ec in
  match Unix.close_process_full (ic, oc, ec) with
  | Unix.WEXITED 0   -> stdout
  | Unix.WEXITED n   -> raise (EvalError (Printf.sprintf "command exited with code %d: %s" n cmd))
  | Unix.WSIGNALED n -> raise (EvalError (Printf.sprintf "command killed by signal %d: %s" n cmd))
  | Unix.WSTOPPED  n -> raise (EvalError (Printf.sprintf "command stopped by signal %d: %s" n cmd))

let exec_command_full cmd =
  let (ic, oc, ec) = Unix.open_process_full ("sh -c " ^ Filename.quote cmd) (Unix.environment ()) in
  close_out oc;
  let stdout = strip_trailing_newline (read_all ic) in
  let stderr = read_all ec in
  let code = match Unix.close_process_full (ic, oc, ec) with
    | Unix.WEXITED n   -> n
    | Unix.WSIGNALED _ -> 128
    | Unix.WSTOPPED  _ -> 128
  in
  (stdout, stderr, code)

let exec_command_full_stdin cmd stdin =
  let (ic, oc, ec) = Unix.open_process_full ("sh -c " ^ Filename.quote cmd) (Unix.environment ()) in
  output_string oc stdin; close_out oc;
  let stdout = strip_trailing_newline (read_all ic) in
  let stderr = read_all ec in
  let code = match Unix.close_process_full (ic, oc, ec) with
    | Unix.WEXITED n   -> n
    | Unix.WSIGNALED _ -> 128
    | Unix.WSTOPPED  _ -> 128
  in
  (stdout, stderr, code)

let shell_result stdout stderr code =
  VConstr ("ShellResult", [VString stdout; VString stderr; VInt code])

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
          | WandEffect ("process_run_stdin", VTuple [VString cmd; VString stdin]) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match (try Ok (exec_command_stdin cmd stdin) with EvalError m -> Error m) with
              | Ok s    -> Effect.Deep.continue    k (VString s)
              | Error m -> Effect.Deep.discontinue k (EvalError m))
          | WandEffect ("process_run_full", VString cmd) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              let (stdout, stderr, code) = exec_command_full cmd in
              Effect.Deep.continue k (shell_result stdout stderr code))
          | WandEffect ("process_run_full_stdin", VTuple [VString cmd; VString stdin]) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              let (stdout, stderr, code) = exec_command_full_stdin cmd stdin in
              Effect.Deep.continue k (shell_result stdout stderr code))
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
          | WandEffect ("fs_temp_file", VTuple [VString prefix; VString suffix]) ->
            Some (fun (k : (a, value) Effect.Deep.continuation) ->
              match (try Ok (Filename.temp_file prefix suffix)
                     with Sys_error m -> Error ("temp_file: " ^ m)) with
              | Ok path -> Effect.Deep.continue    k (VPath path)
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

(* Path resolution, `import`-expression matching, and other purely
   type/AST-level pieces of this live in `Module_types` (shared with
   `Evaluator`'s `Types` primitives, which typecheck imports without
   evaluating them). Only the parts that need `Evaluator.value`/`eval` stay
   here. *)
let add_ext          = Module_types.add_ext
let resolve_import    = Module_types.resolve_import
let namespace_name_of = Module_types.namespace_name_of
let local_tenv_of     = Module_types.local_tenv_of
let is_private        = Module_types.is_private
let strip_located     = Module_types.strip_located
let import_kind_of    = Module_types.import_kind_of

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

(* ── Multi-clause merging ─────────────────────────────────────────────────── *)

(* True for patterns that unconditionally match (no structural constraint). *)
let is_catchall_pat = function
  | Ast.PVar _ | Ast.Wild -> true
  | _ -> false

(* Extract the match arms from a previously merged VFix, or return a single arm. *)
let extract_arms arity existing_params existing_body =
  let fresh     = List.init arity (fun i -> Printf.sprintf "_p%d" i) in
  let fresh_pats = List.map (fun v -> Ast.PVar v) fresh in
  let scrutinee = match fresh with
    | [v] -> Ast.Var v
    | vs  -> Ast.Tuple (List.map (fun v -> Ast.Var v) vs)
  in
  if existing_params = fresh_pats then
    match strip_located existing_body with
    | Ast.Match (scrut, arms) when strip_located scrut = scrutinee -> arms
    | body ->
      let pat = match existing_params with [p] -> p | ps -> Ast.PTuple ps in
      [(pat, None, body)]
  else
    let pat = match existing_params with [p] -> p | ps -> Ast.PTuple ps in
    [(pat, None, existing_body)]

(* Merge a new clause into an existing same-arity VFix.
   Specific patterns are placed before catch-all patterns so that
   a base case added after a catch-all still fires correctly.
   Within each group the new clause takes precedence. *)
let merge_clause env name arity params body existing_params existing_body =
  let fresh     = List.init arity (fun i -> Printf.sprintf "_p%d" i) in
  let scrutinee = match fresh with
    | [v] -> Ast.Var v
    | vs  -> Ast.Tuple (List.map (fun v -> Ast.Var v) vs)
  in
  let new_pat  = match params with [p] -> p | ps -> Ast.PTuple ps in
  let new_arm  = (new_pat, None, body) in
  let old_arms = extract_arms arity existing_params existing_body in
  let (new_sp, new_ca) =
    if is_catchall_pat new_pat then ([], [new_arm]) else ([new_arm], []) in
  let (old_sp, old_ca) =
    List.partition (fun (p, _, _) -> not (is_catchall_pat p)) old_arms in
  let arms = new_sp @ old_sp @ new_ca @ old_ca in
  VFix (name, env, List.map (fun v -> Ast.PVar v) fresh, Ast.Match (scrutinee, arms))

(* Evaluate a single top-level item; imports already merged into env *)
let run_item env item =
  match item with
  | Ast.TLLet (_, [], body) when Option.is_some (import_kind_of body) -> env  (* pre-loaded *)
  | Ast.TLLet (name, [], body) ->
    (name, eval env body) :: env
  | Ast.TLLet (name, params, body) ->
    (name, VFix (name, env, params, body)) :: env
  | Ast.TLLetRec bindings ->
    List.fold_left (fun acc (name, _, _) ->
      (name, VFixGroup (bindings, env, name)) :: acc) env bindings
  | Ast.TLLetPat (_, body) when Option.is_some (import_kind_of body) -> env  (* pre-loaded *)
  | Ast.TLLetPat (pat, e) ->
    Evaluator.bind_pat pat (eval env e) env
  | Ast.TLImport _ -> env  (* already loaded by load_imports_for *)
  | Ast.TLType (Ast.Variants (_, _, ctors)) ->
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

type module_result = import_env * (string * Typechecker.scheme) list * env * (string * string) list

(* Load imports for a program.
   `cache` maps path -> result so each module is loaded once per run_program.
   `loading` detects import cycles. *)
let rec load_imports_for ~base_dir ~cache ~loading prog =
  List.fold_left (fun (acc, acc_docs) item ->
    let load_kind kind =
      let full = resolve_import base_dir kind in
      match Hashtbl.find_opt cache full with
      | Some cached -> cached
      | None ->
        if List.mem full !loading then failwith ("import cycle detected: " ^ full)
        else load_module full ~cache ~loading
    in
    let bind_field own_type own_eval field alias =
      let t = match List.assoc_opt field own_type with
        | Some s -> s
        | None -> failwith (Printf.sprintf "module has no exported symbol '%s'" field)
      in
      let v = match List.assoc_opt field own_eval with
        | Some v -> v
        | None -> failwith (Printf.sprintf "module has no exported symbol '%s'" field)
      in
      ((alias, t), (alias, v))
    in
    let add_import modul_import type_entries eval_entries mod_docs =
      ({ tenv     = modul_import.tenv @ acc.tenv;
         type_env = type_entries @ modul_import.type_env @ acc.type_env;
         eval_env = eval_entries @ modul_import.eval_env @ acc.eval_env },
       mod_docs @ acc_docs)
    in
    match item with
    | Ast.TLImport kind ->
      let ns_name = namespace_name_of kind in
      let (modul_import, own_type, own_eval, mod_docs) = load_kind kind in
      let prefixed_docs = List.map (fun (n, d) -> (ns_name ^ "." ^ n, d)) mod_docs in
      add_import modul_import
        [(ns_name, Typechecker.Namespace own_type)]
        [(ns_name, VRecord own_eval)]
        prefixed_docs
    | Ast.TLLet (name, [], body) when Option.is_some (import_kind_of body) ->
      let kind = Option.get (import_kind_of body) in
      let (modul_import, own_type, own_eval, mod_docs) = load_kind kind in
      let prefixed_docs = List.map (fun (n, d) -> (name ^ "." ^ n, d)) mod_docs in
      add_import modul_import
        [(name, Typechecker.Namespace own_type)]
        [(name, VRecord own_eval)]
        prefixed_docs
    | Ast.TLLetPat (pat, body) when Option.is_some (import_kind_of body) ->
      let kind = Option.get (import_kind_of body) in
      let (modul_import, own_type, own_eval, mod_docs) = load_kind kind in
      let (type_entries, eval_entries, extra_docs) = match pat with
        | Ast.PVar name ->
          let pdocs = List.map (fun (n, d) -> (name ^ "." ^ n, d)) mod_docs in
          [(name, Typechecker.Namespace own_type)],
          [(name, VRecord own_eval)],
          pdocs
        | Ast.PMap binds ->
          let te, ee = List.map (fun (field, p) ->
            match p with
            | Ast.PVar alias -> bind_field own_type own_eval field alias
            | _ -> failwith "import destructuring only supports name bindings"
          ) binds |> List.split in
          te, ee, []
        | Ast.PList pats ->
          let te, ee = List.map (fun p ->
            match p with
            | Ast.PVar name -> bind_field own_type own_eval name name
            | _ -> failwith "import destructuring only supports name bindings"
          ) pats |> List.split in
          te, ee, []
        | _ -> failwith "unsupported pattern in import destructuring"
      in
      add_import modul_import type_entries eval_entries extra_docs
    | _ -> (acc, acc_docs)
  ) (empty_import_env, []) prog.Ast.items

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
  let (imported, imp_docs) = load_imports_for ~base_dir ~cache ~loading prog in
  let result =
    (match Typechecker.infer_program_env_with_own
             ~init_tenv:imported.tenv ~init_env:imported.type_env prog with
     | Error msg -> failwith ("type error: " ^ msg)
     | Ok (type_env, own_type) ->
       let base = stdlib_eval_env @ imported.eval_env in
       let full_eval = List.fold_left run_item base prog.Ast.items in
       let n_own = List.length full_eval - List.length base in
       let own_eval = List.filteri (fun i _ -> i < n_own) full_eval
         |> List.filter (fun (n, _) -> not (is_private n)) in
       let own_type = List.filter (fun (n, _) -> not (is_private n)) own_type in
       let full_import = { tenv     = local_tenv_of prog @ imported.tenv;
                           type_env;
                           eval_env = full_eval } in
       (full_import, own_type, own_eval, prog.Ast.docs @ imp_docs))
  in
  Hashtbl.replace cache path result;
  loading := List.filter (fun p -> p <> path) !loading;
  result

(* ── Run a parsed program ─────────────────────────────────────────────────── *)

let run_program ~base_dir prog =
  let cache = Hashtbl.create 8 in
  let loading = ref [] in
  let (imp, _) = load_imports_for ~base_dir ~cache ~loading prog in
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

(* ── `wand test` ──────────────────────────────────────────────────────────── *)

(* A test file's top-level expressions are the `stdlib/Test.wand` module's
   `Pass`/`Fail` constructors (see Test.wand's `test` function); a raised
   runtime error is reported the same way a deliberate Fail would be, just
   without a caller-chosen message. Any other top-level expression's value
   is simply not a test outcome and is ignored (still executed normally,
   e.g. ordinary setup code/side effects). Only lex/parse/type errors for
   the whole file are fatal -- each TLExpr's *evaluation* is isolated so
   one failing/raising test doesn't stop the rest of the file. *)
type test_outcome = TPass of string | TFail of string | TError of string

let run_test_program ~base_dir prog : (test_outcome list, string) result =
  let cache = Hashtbl.create 8 in
  let loading = ref [] in
  let (imp, _) = load_imports_for ~base_dir ~cache ~loading prog in
  match Typechecker.infer_program_env ~init_tenv:imp.tenv ~init_env:imp.type_env prog with
  | Error msg -> Error ("type error: " ^ msg)
  | Ok _ ->
    let outcomes = ref [] in
    ignore (run_with_default_handler (fun () ->
      ignore (List.fold_left (fun env item ->
        match item with
        | Ast.TLExpr e ->
          let result =
            try Ok (eval env e)
            with
            | EvalError msg -> Error msg
            | Failure msg   -> Error msg
          in
          (match result with
           | Ok (VConstr ("Pass", [VString label])) -> outcomes := !outcomes @ [TPass label]
           | Ok (VConstr ("Fail", [VString msg]))   -> outcomes := !outcomes @ [TFail msg]
           | Ok _    -> ()
           | Error m -> outcomes := !outcomes @ [TError m]);
          env
        | _ -> run_item env item
      ) (base_eval_env @ imp.eval_env) prog.Ast.items);
      VUnit
    ));
    Ok !outcomes

let run_test_file path : (test_outcome list, string) result =
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
    run_test_program ~base_dir prog
  with
  | Sys_error msg         -> Error ("cannot open file: " ^ msg)
  | Lexer.LexError msg    -> Error ("lex error: " ^ msg)
  | Parser.ParseError msg -> Error ("parse error: " ^ msg)
  | EvalError msg         -> Error ("eval error: " ^ msg)
  | Failure msg           -> Error (msg)

(* ── REPL session ─────────────────────────────────────────────────────────── *)

type repl_result =
  | RBind     of string * string
  | RType     of string
  | RVal      of string * string
  | RTypeExpr of string
  | RHoles    of string list
  | RSilent

type session = {
  s_tenv      : (string * Ast.type_def) list;
  s_type_env  : Typechecker.env;
  s_eval_env  : env;
  s_cache     : (string, module_result) Hashtbl.t;
  s_base_dir  : string;
  s_last_load : string option;
  s_sources   : (string * string) list;  (* name -> source text *)
  s_docs      : (string * string) list;  (* name -> doc string *)
}

let make_session ?(base_dir = Sys.getcwd ()) () = {
  s_tenv      = [];
  s_type_env  = [];
  s_eval_env  = [];
  s_cache     = Hashtbl.create 8;
  s_base_dir  = base_dir;
  s_last_load = None;
  s_sources   = [];
  s_docs      = [];
}

let lookup_type (sess : session) (name : string) : string option =
  match String.split_on_char '.' name with
  | [ns; member] ->
    (match List.assoc_opt ns sess.s_type_env with
     | Some (Typechecker.Namespace members) ->
       (match List.assoc_opt member members with
        | Some s -> Some (Typechecker.string_of_scheme s)
        | None   -> None)
     | _ -> None)
  | [plain] ->
    (match List.assoc_opt plain sess.s_type_env with
     | Some s -> Some (Typechecker.string_of_scheme s)
     | None   -> None)
  | _ -> None

let last_non_import prog =
  List.fold_left (fun acc item ->
    match item with Ast.TLImport _ -> acc | other -> Some other
  ) None prog.Ast.items

let run_session (sess : session) (src : string) : (session * repl_result, string) result =
  try
    let tokens = Lexer.tokenize src in
    let prog   = Parser.parse_program tokens in
    let loading = ref [] in
    let (imp, imp_docs) = load_imports_for ~base_dir:sess.s_base_dir ~cache:sess.s_cache ~loading prog in
    let merged_tenv     = local_tenv_of prog @ imp.tenv @ sess.s_tenv in
    let merged_type_env = imp.type_env @ sess.s_type_env in
    match Typechecker.infer_program_full_with_own
            ~init_tenv:merged_tenv ~init_env:merged_type_env prog with
    | Error msg -> Error ("type error: " ^ msg)
    | Ok (full_type_env, own_type_env, last_t, hole_types) ->
      let dedup lst =
        let seen = Hashtbl.create 16 in
        List.filter (fun (k, _) ->
          if Hashtbl.mem seen k then false
          else (Hashtbl.add seen k (); true)) lst
      in
      if hole_types <> [] then begin
        (* Holes present — skip evaluation, report hole types *)
        let new_sources =
          List.filter_map (function
            | Ast.TLLet (name, _, _) -> Some (name, src)
            | _ -> None) prog.Ast.items
        in
        let new_sess = { sess with
          s_tenv     = dedup (local_tenv_of prog @ imp.tenv @ sess.s_tenv);
          s_type_env = dedup (own_type_env @ imp.type_env @ sess.s_type_env);
          s_sources  = new_sources @ sess.s_sources;
          s_docs     = prog.Ast.docs @ imp_docs @ sess.s_docs;
        } in
        let hole_strs = List.map Typechecker.string_of_typ hole_types in
        Ok (new_sess, RHoles hole_strs)
      end else begin
        let base_eval = base_eval_env @ imp.eval_env @ sess.s_eval_env in
        let env_ref  = ref base_eval in
        let last_ref = ref VUnit in
        ignore (run_with_default_handler (fun () ->
          List.iter (fun item ->
            match item with
            | Ast.TLLet (_, [], body) when Option.is_some (import_kind_of body) -> ()  (* pre-loaded *)
            | Ast.TLLet (name, [], body) ->
              env_ref := (name, eval !env_ref body) :: !env_ref
            | Ast.TLLet (name, params, body) ->
              let arity = List.length params in
              let v = match List.assoc_opt name !env_ref with
                | Some (VFix (_, _, ep, eb)) when List.length ep = arity ->
                  merge_clause !env_ref name arity params body ep eb
                | _ -> VFix (name, !env_ref, params, body)
              in
              env_ref := (name, v) :: !env_ref
            | Ast.TLLetRec bindings ->
              List.iter (fun (name, _, _) ->
                env_ref := (name, VFixGroup (bindings, !env_ref, name)) :: !env_ref
              ) bindings
            | Ast.TLLetPat (_, body) when Option.is_some (import_kind_of body) -> ()  (* pre-loaded *)
            | Ast.TLLetPat (pat, e) ->
              env_ref := Evaluator.bind_pat pat (eval !env_ref e) !env_ref
            | Ast.TLType (Ast.Variants (_, _, ctors)) ->
              List.iter (fun ctor ->
                Hashtbl.replace constr_fields ctor.Ast.name (List.map fst ctor.Ast.fields);
                env_ref := (ctor.Ast.name,
                  match ctor.Ast.fields with
                  | [] -> VConstr (ctor.Ast.name, [])
                  | _  -> VPartialConstr (ctor.Ast.name, List.length ctor.Ast.fields, [])
                ) :: !env_ref
              ) ctors
            | Ast.TLExpr e ->
              last_ref := eval !env_ref e
            | Ast.TLImport _ -> ()
          ) prog.Ast.items;
          VUnit));
        let new_eval_env = !env_ref in
        let last_v       = !last_ref in
        let n_own = List.length new_eval_env - List.length base_eval in
        let own_eval_env = List.filteri (fun i _ -> i < n_own) new_eval_env in
        let new_sources =
          List.filter_map (function
            | Ast.TLLet (name, _, _) -> Some (name, src)
            | _ -> None) prog.Ast.items
        in
        (* Keep only namespace entries from imports — raw primitives come from
           the typechecker/evaluator base and don't belong in the session. *)
        let new_sess = { sess with
          s_tenv     = dedup (local_tenv_of prog @ imp.tenv @ sess.s_tenv);
          s_type_env = dedup (own_type_env @ imp.type_env @ sess.s_type_env);
          s_eval_env = dedup (own_eval_env @ imp.eval_env @ sess.s_eval_env);
          s_sources  = new_sources @ sess.s_sources;
          s_docs     = prog.Ast.docs @ imp_docs @ sess.s_docs;
        } in
        let display = match last_non_import prog with
          | None -> RSilent
          | Some (Ast.TLLet (name, _, _)) ->
            (match List.assoc_opt name full_type_env with
             | Some s -> RBind (name, Typechecker.string_of_scheme s)
             | None   -> RBind (name, "?"))
          | Some (Ast.TLLetPat _) -> RSilent
          | Some (Ast.TLType (Ast.Variants (name, _, _))) -> RType name
          | Some (Ast.TLExpr _) ->
            (match last_v with
             | VUnit -> RSilent
             | v     -> RVal (show_value v, Typechecker.string_of_typ last_t))
          | Some _ -> RSilent
        in
        Ok (new_sess, display)
      end
  with
  | Lexer.LexError msg    -> Error ("lex error: " ^ msg)
  | Parser.ParseError msg -> Error ("parse error: " ^ msg)
  | EvalError msg         -> Error ("runtime error: " ^ msg)
  | Failure msg           -> Error msg

let typecheck_session (sess : session) (src : string) : (repl_result, string) result =
  try
    let tokens = Lexer.tokenize src in
    let prog   = Parser.parse_program tokens in
    let loading = ref [] in
    let (imp, _) = load_imports_for ~base_dir:sess.s_base_dir ~cache:sess.s_cache ~loading prog in
    let merged_tenv     = local_tenv_of prog @ imp.tenv @ sess.s_tenv in
    let merged_type_env = imp.type_env @ sess.s_type_env in
    match Typechecker.infer_program_full_with_own
            ~init_tenv:merged_tenv ~init_env:merged_type_env prog with
    | Error msg -> Error ("type error: " ^ msg)
    | Ok (full_type_env, _, last_t, hole_types) ->
      if hole_types <> [] then
        Ok (RHoles (List.map Typechecker.string_of_typ hole_types))
      else
        let display = match last_non_import prog with
          | None -> RSilent
          | Some (Ast.TLLet (name, _, _)) ->
            (match List.assoc_opt name full_type_env with
             | Some s -> RBind (name, Typechecker.string_of_scheme s)
             | None   -> RBind (name, "?"))
          | Some (Ast.TLType (Ast.Variants (name, _, _))) -> RType name
          | Some (Ast.TLExpr _) -> RTypeExpr (Typechecker.string_of_typ last_t)
          | Some _ -> RSilent
        in
        Ok display
  with
  | Lexer.LexError msg    -> Error ("lex error: " ^ msg)
  | Parser.ParseError msg -> Error ("parse error: " ^ msg)
  | Failure msg           -> Error msg
