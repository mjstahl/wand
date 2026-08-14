(* What a module costs to load, kept between runs.

   Loading a module is read, lex, parse, infer, evaluate. Measured on a
   200-definition module: 0.04ms, 0.31ms, 0.99ms, 5.72ms, 0.17ms. Inference
   is almost all of it and evaluation is almost none, so what is worth
   keeping is the front end's answer -- the parsed program and the types it
   inferred -- and evaluation runs again every time from the parsed form.

   Nothing here holds a closure. `Marshal` cannot write one, and an
   evaluation environment is made of them; the types and the syntax tree are
   ordinary data.

   ── Staleness ────────────────────────────────────────────────────────────
   A module's types are inferred against its imports, so its entry is only
   good while they are unchanged too. The key is the hash of the module's own
   source *and* of everything it imports, transitively. That makes a stale
   entry unreachable rather than merely unused: change anything in the
   closure and the key changes, so nothing has to notice the change or check
   for it. The alternative -- key on the file alone and record what its
   imports hashed to -- keeps fewer entries and makes validity something
   checked rather than guaranteed. Reading a dependency's bytes is the cheap
   part of loading it, so the guarantee is nearly free. *)

let disabled = Sys.getenv_opt "WAND_NO_CACHE" <> None

(* Bumped when the shape of what is written changes. An old entry then has a
   different key rather than being read back as the wrong shape -- Marshal
   will happily hand back nonsense typed as whatever the reader expected. *)
let format_version = "1"

let dir () =
  let base =
    match Sys.getenv_opt "XDG_CACHE_HOME" with
    | Some d when d <> "" -> d
    | _ ->
      (match Sys.getenv_opt "HOME" with
       | Some h -> Filename.concat h ".cache"
       | None -> Filename.get_temp_dir_name ())
  in
  Filename.concat base "wand"

(* Best-effort: a cache that cannot be created is a cache that is not used,
   never an error a script has to hear about. *)
let ensure_dir () =
  let d = dir () in
  if not (Sys.file_exists d) then
    (try
       let parent = Filename.dirname d in
       if not (Sys.file_exists parent) then Unix.mkdir parent 0o755;
       Unix.mkdir d 0o755
     with Unix.Unix_error _ -> ());
  d

let key ~source ~deps =
  Digest.to_hex
    (Digest.string
       (String.concat "\000" (format_version :: source :: List.sort compare deps)))

let path_for key = Filename.concat (dir ()) (key ^ ".wandc")

let find (key : string) : 'a option =
  if disabled then None
  else
    let p = path_for key in
    if not (Sys.file_exists p) then None
    else
      try
        In_channel.with_open_bin p (fun ic -> Some (Marshal.from_channel ic))
      with _ ->
        (* A truncated or unreadable entry is a cache miss, not a failure:
           two runs writing at once, a half-written file, a format that moved
           on. Drop it and let the caller do the work. *)
        (try Sys.remove p with _ -> ());
        None

let store (key : string) (value : 'a) : unit =
  if not disabled then begin
    let d = ensure_dir () in
    if Sys.file_exists d then
      try
        (* Written beside and renamed into place, so a reader never sees a
           half-written entry: two runs of the same script race often. *)
        let tmp = Filename.concat d (key ^ "." ^ string_of_int (Unix.getpid ()) ^ ".tmp") in
        Out_channel.with_open_bin tmp (fun oc -> Marshal.to_channel oc value []);
        Sys.rename tmp (path_for key)
      with _ -> ()
  end
