(* ── Import path resolution ───────────────────────────────────────────────── *)

(* Pure import path handling, shared by `Runner` and `Evaluator`. Lives below
   `Evaluator` in the dependency graph -- it touches only
   `Ast`/`Lexer`/`Parser`, never `Evaluator.value` -- so both can depend on it
   without a cycle. *)

let add_ext p = if Filename.check_suffix p ".wand" then p else p ^ ".wand"

(* Where a module's source comes from. The standard library is carried in
   the binary, so it has no path and no directory to be found in; a user
   module is a file. Keeping the two apart in the type is what lets one
   loader serve both without a filesystem lookup standing in for "is this
   the standard library". *)
type source =
  | Embedded of string (* a standard library module, by name *)
  | File of string (* a path on disk *)

(* The name a module is known by while loading: the import cache, the cycle
   check and the compile cache's dependency keys are all keyed on this. An
   embedded module's key is a path that cannot exist, so it can never
   collide with a user file -- and `Filename.dirname` of it gives the base
   directory its own imports resolve against, which for a stdlib module is
   never consulted, because everything it imports is another stdlib module. *)
let stdlib_base_dir = "<stdlib>"

let key_of = function
  | Embedded name -> Filename.concat stdlib_base_dir (name ^ ".wand")
  | File path -> path

(* `WAND_STDLIB` points at a standard library to use instead of the embedded
   one. It is a development override -- run a built binary against a working
   tree -- rather than how the library is normally found. Empty counts as
   unset: an empty value almost always arrives from a shell interpolating a
   variable that held nothing, and reading that as "use the directory named
   by nothing" breaks every run for a reason nobody can see. *)
let stdlib_override () =
  match Sys.getenv_opt "WAND_STDLIB" with
  | Some dir when String.trim dir <> "" -> Some (String.trim dir)
  | _ -> None

let embedded_module name =
  match List.assoc_opt name Stdlib_embed.table with
  | Some _ -> Some name
  | None ->
    (* Case is a fallback, not the rule: `import List` is how the module is
       written, and `import list` finds it rather than reporting that no
       such module exists. Spelled out here because a table has no case
       rules of its own, and leaving it to the platform is how a script
       comes to run on one machine and not another. *)
    let lower = String.lowercase_ascii name in
    List.find_map
      (fun (n, _) -> if String.lowercase_ascii n = lower then Some n else None)
      Stdlib_embed.table

let resolve_stdlib name =
  match stdlib_override () with
  | Some dir ->
    let exact = Filename.concat dir (name ^ ".wand") in
    if Sys.file_exists exact then File exact
    else
      let lower =
        Filename.concat dir (String.lowercase_ascii name ^ ".wand")
      in
      if Sys.file_exists lower then File lower
      else
        (* Pointing at the wrong directory is the likely mistake, and it is
           worth saying so: the override is the only thing standing between
           the run and a standard library that is known to be present. *)
        failwith
          (Printf.sprintf
             "no standard library module named '%s': WAND_STDLIB is set to \
              %S, which has no %s.wand. Unset it to use the standard library \
              built into this binary."
             name dir name)
  | None ->
    (match embedded_module name with
     | Some n -> Embedded n
     | None ->
       failwith
         (Printf.sprintf
            "no standard library module named '%s'. This binary carries: %s."
            name
            (String.concat ", " (List.map fst Stdlib_embed.table))))

let resolve_import base_dir = function
  | Ast.StdlibModule name -> resolve_stdlib name
  | Ast.UserPath path ->
    File
      (if Filename.is_relative path
       then Filename.concat base_dir (add_ext path)
       else add_ext path)

let read_source = function
  | Embedded name ->
    (match List.assoc_opt name Stdlib_embed.table with
     | Some src -> src
     | None -> failwith ("no standard library module named '" ^ name ^ "'"))
  | File path ->
    (try In_channel.with_open_text path In_channel.input_all
     with Sys_error msg -> failwith ("cannot import '" ^ path ^ "': " ^ msg))

(* Whether a directory is a standard library, asked of a directory someone
   already named rather than searched for. A directory holding every module
   this binary carries is one; a directory that happens to contain a file
   called `List.wand` is not. That distinction is the whole reason the
   upward search is gone, so it is not re-introduced here. *)
let is_stdlib_dir dir =
  Stdlib_embed.table <> []
  && List.for_all
       (fun (name, _) -> Sys.file_exists (Filename.concat dir (name ^ ".wand")))
       Stdlib_embed.table

(* Only stdlib imports bind a namespace implicitly, and there the name is
   written at the import site: `import FS` binds `FS`. A user-path import
   must state its binding -- `let utils = import ./utils` or a destructuring
   pattern -- so the name a module arrives under is greppable, rather than
   being derived by capitalising a filename. *)
let namespace_name_of = function
  | Ast.StdlibModule name -> name
  | Ast.UserPath path ->
    failwith (Printf.sprintf
      "bare `import %s` does not bind a name; write `let name = import %s` \
       or destructure it: `let {foo, bar} = import %s`" path path path)

let strip_located = Ast.strip_located

let import_kind_of e = match strip_located e with
  | Ast.ImportExpr k -> Some k
  | _ -> None

let local_tenv_of prog =
  List.filter_map (function
    | Ast.TLType ((Ast.Variants (n, _, _) | Ast.Alias (n, _, _)) as tdef) ->
      Some (n, tdef)
    | _ -> None) prog.Ast.items

let is_private name = String.length name > 0 && name.[0] = '_'
