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
              Effect.Deep.continue k (VString (exec_command cmd)))
          | _ -> None
    }

(* ── Import resolution ────────────────────────────────────────────────────── *)

let add_ext p = if Filename.check_suffix p ".wand" then p else p ^ ".wand"

let resolve_import base_dir path =
  if Filename.is_relative path
  then Filename.concat base_dir (add_ext path)
  else add_ext path

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
    | Ast.TLType tdef ->
      let n = match tdef with Ast.Variants(n,_) | Ast.RecordType(n,_) -> n in
      Some (n, tdef)
    | _ -> None) prog.Ast.items

(* Evaluate a single top-level item; imports already merged into env *)
let run_item env item =
  match item with
  | Ast.TLLet (name, [], body) ->
    (name, eval env body) :: env
  | Ast.TLLet (name, params, body) ->
    (name, VFix (name, env, params, body)) :: env
  | Ast.TLImport _ -> env
  | Ast.TLType (Ast.Variants (_, ctors)) ->
    List.fold_left (fun env ctor ->
      let v = match ctor.Ast.fields with
        | [] -> VConstr (ctor.Ast.name, [])
        | fs -> VPartialConstr (ctor.Ast.name, List.length fs, [])
      in
      (ctor.Ast.name, v) :: env
    ) env ctors
  | Ast.TLType (Ast.RecordType (type_name, _)) ->
    (type_name, VRecordCtor) :: env

(* ── Module loading ───────────────────────────────────────────────────────── *)

(* Load imports for a program; visited is shared to detect cycles *)
let rec load_imports_for ~base_dir ~visited prog =
  List.fold_left (fun acc item ->
    match item with
    | Ast.TLImport path ->
      let full = resolve_import base_dir path in
      if List.mem full !visited then acc
      else begin
        visited := full :: !visited;
        merge_import_env acc (load_module full visited)
      end
    | _ -> acc
  ) empty_import_env prog.Ast.items

and load_module path visited =
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
  let imported = load_imports_for ~base_dir ~visited prog in
  (match Typechecker.infer_program_env ~init_tenv:imported.tenv ~init_env:imported.type_env prog with
   | Error msg -> failwith ("type error: " ^ msg)
   | Ok type_env ->
     let eval_env = List.fold_left run_item imported.eval_env prog.Ast.items in
     { tenv     = local_tenv_of prog @ imported.tenv;
       type_env;
       eval_env })

(* ── Run a parsed program ─────────────────────────────────────────────────── *)

let run_program ~base_dir prog =
  let visited = ref [] in
  let imp = load_imports_for ~base_dir ~visited prog in
  (match Typechecker.infer_program_env ~init_tenv:imp.tenv ~init_env:imp.type_env prog with
   | Error msg -> Error ("type error: " ^ msg)
   | Ok _ ->
     let result = run_with_default_handler (fun () ->
       let env = List.fold_left run_item (base_eval_env @ imp.eval_env) prog.Ast.items in
       match prog.Ast.start with
       | None   -> VUnit
       | Some e -> eval env e
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
