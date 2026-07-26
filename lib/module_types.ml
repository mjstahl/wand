(* ── Import path resolution ───────────────────────────────────────────────── *)

(* Pure, filesystem-and-type-level import handling shared by `Runner` (which
   also evaluates imported modules) and `Evaluator`'s `Types` primitives
   (which only need to typecheck a snippet against its imports, not run any
   of them). Lives below `Evaluator` in the dependency graph -- it only
   touches `Ast`/`Lexer`/`Parser`/`Typechecker`, never `Evaluator.value` -- so
   both can depend on it without a cycle. *)

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

let rec strip_located = function
  | Ast.Located (_, e) -> strip_located e
  | e -> e

let import_kind_of e = match strip_located e with
  | Ast.ImportExpr k -> Some k
  | _ -> None

let local_tenv_of prog =
  List.filter_map (function
    | Ast.TLType (Ast.Variants (n, _, _) as tdef) -> Some (n, tdef)
    | _ -> None) prog.Ast.items

let is_private name = String.length name > 0 && name.[0] = '_'

(* ── Type-only import resolution ──────────────────────────────────────────── *)

(* Mirrors `Runner.load_imports_for`/`load_module`'s type side, but never
   evaluates an imported module -- only typechecks it (via
   `Typechecker.infer_program_env_with_own`, which already uses
   `stdlib_type_env` as its base). Used by `Types.check_program`/`holes` so
   `import`s inside a snippet resolve to their real inferred types instead of
   being silently ignored. *)

type type_import_env = {
  tenv     : (string * Ast.type_def) list;
  type_env : Typechecker.env;
}

let empty_type_import_env = { tenv = []; type_env = [] }

let rec infer_imports_for ~base_dir ~cache ~loading prog =
  List.fold_left (fun acc item ->
    let load_kind kind =
      let full = resolve_import base_dir kind in
      match Hashtbl.find_opt cache full with
      | Some cached -> cached
      | None ->
        if List.mem full !loading then failwith ("import cycle detected: " ^ full)
        else infer_module full ~cache ~loading
    in
    let bind_field own_type field alias =
      match List.assoc_opt field own_type with
      | Some s -> (alias, s)
      | None -> failwith (Printf.sprintf "module has no exported symbol '%s'" field)
    in
    let add_import modul_import type_entries =
      { tenv     = modul_import.tenv @ acc.tenv;
        type_env = type_entries @ modul_import.type_env @ acc.type_env }
    in
    match item with
    | Ast.TLImport kind ->
      let ns_name = namespace_name_of kind in
      let (modul_import, own_type) = load_kind kind in
      add_import modul_import [(ns_name, Typechecker.Namespace own_type)]
    | Ast.TLLet (name, [], body) when Option.is_some (import_kind_of body) ->
      let kind = Option.get (import_kind_of body) in
      let (modul_import, own_type) = load_kind kind in
      add_import modul_import [(name, Typechecker.Namespace own_type)]
    | Ast.TLLetPat (pat, body) when Option.is_some (import_kind_of body) ->
      let kind = Option.get (import_kind_of body) in
      let (modul_import, own_type) = load_kind kind in
      let type_entries = match pat with
        | Ast.PVar name -> [(name, Typechecker.Namespace own_type)]
        | Ast.PMap binds ->
          List.map (fun (field, p) -> match p with
            | Ast.PVar alias -> bind_field own_type field alias
            | _ -> failwith "import destructuring only supports name bindings") binds
        | Ast.PList pats ->
          List.map (fun p -> match p with
            | Ast.PVar name -> bind_field own_type name name
            | _ -> failwith "import destructuring only supports name bindings") pats
        | _ -> failwith "unsupported pattern in import destructuring"
      in
      add_import modul_import type_entries
    | _ -> acc
  ) empty_type_import_env prog.Ast.items

and infer_module path ~cache ~loading =
  let src =
    try In_channel.with_open_text path In_channel.input_all
    with Sys_error msg -> failwith ("cannot import '" ^ path ^ "': " ^ msg)
  in
  let tokens =
    try Lexer.tokenize src
    with Lexer.LexError msg -> failwith ("lex error in '" ^ path ^ "': " ^ msg)
  in
  let prog =
    try Parser.parse_program tokens
    with Parser.ParseError msg -> failwith ("parse error in '" ^ path ^ "': " ^ msg)
  in
  let base_dir = Filename.dirname path in
  loading := path :: !loading;
  let imported = infer_imports_for ~base_dir ~cache ~loading prog in
  let result =
    match Typechecker.infer_program_env_with_own
            ~init_tenv:imported.tenv ~init_env:imported.type_env prog with
    | Error msg -> failwith ("type error: " ^ msg)
    | Ok (type_env, own_type) ->
      let own_type = List.filter (fun (n, _) -> not (is_private n)) own_type in
      let full_import = { tenv = local_tenv_of prog @ imported.tenv; type_env } in
      (full_import, own_type)
  in
  Hashtbl.replace cache path result;
  loading := List.filter (fun p -> p <> path) !loading;
  result
