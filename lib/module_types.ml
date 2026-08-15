(* ── Import path resolution ───────────────────────────────────────────────── *)

(* Pure import path handling, shared by `Runner` and `Evaluator`. Lives below
   `Evaluator` in the dependency graph -- it touches only
   `Ast`/`Lexer`/`Parser`, never `Evaluator.value` -- so both can depend on it
   without a cycle. *)

let add_ext p = if Filename.check_suffix p ".wand" then p else p ^ ".wand"

(* `WAND_STDLIB` points at a standard library to use instead of the one that
   would be found. Empty counts as unset: an empty value almost always
   arrives from a shell interpolating a variable that held nothing, and
   reading that as "use the directory named by nothing" breaks every run for
   a reason nobody can see. *)
let find_stdlib_dir_uncached () =
  match Sys.getenv_opt "WAND_STDLIB" with
  | Some dir when String.trim dir <> "" -> dir
  | _ ->
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

(* The directory does not move while the process runs, and the search above
   walks the tree from CWD -- which every stdlib import would otherwise
   repeat. *)
let stdlib_dir_cache : string option ref = ref None

let find_stdlib_dir () =
  match !stdlib_dir_cache with
  | Some dir -> dir
  | None ->
    let dir = find_stdlib_dir_uncached () in
    stdlib_dir_cache := Some dir;
    dir

let resolve_stdlib name =
  let stdlib_dir = find_stdlib_dir () in
  let exact = Filename.concat stdlib_dir (name ^ ".wand") in
  if Sys.file_exists exact then exact
  else
    let lower = Filename.concat stdlib_dir (String.lowercase_ascii name ^ ".wand") in
    if Sys.file_exists lower then lower
    else if not (Sys.file_exists stdlib_dir) then
      (* The library itself is missing, which is not the same as a script
         forgetting to import it -- and saying "did you forget to import
         List?" to someone whose wand cannot find its own standard library
         sends them to look at their code. *)
      failwith
        (Printf.sprintf
           "cannot find the standard library: no directory at %s.%s"
           stdlib_dir
           (match Sys.getenv_opt "WAND_STDLIB" with
            | Some d when String.trim d <> "" ->
              Printf.sprintf " WAND_STDLIB is set to %S." d
            | _ ->
              " Set WAND_STDLIB to point at one, or run where stdlib/ is above you."))
    else exact

let resolve_import base_dir = function
  | Ast.StdlibModule name -> resolve_stdlib name
  | Ast.UserPath path ->
    if Filename.is_relative path
    then Filename.concat base_dir (add_ext path)
    else add_ext path

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
       or destructure it: `let [foo, bar] = import %s`" path path path)

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
