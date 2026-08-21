(* Lints run inside `wand t` rather than as a separate command: the typecheck
   is the step an editing loop already repeats, and a rule that does not
   surface there is a rule its audience never sees.

   This module only finds violations and locates them. What each rule is
   called, how it is classified, and what it says all live in `Lint_rules`. *)

(* A machine-applicable correction, carried alongside the human text so a
   tool consuming `--json` can fix without re-parsing prose. The type lives
   in `Diag` so findings and errors share one fix representation; it is
   re-exported here because the constructors read as lint vocabulary. *)
type fix = Diag.fix =
  | InsertLine  of string   (* a line the file lacks (the manifest) *)
  | ReplaceLine of string   (* the corrected form of the flagged line *)
  | DeleteLine              (* the flagged line should not exist *)
  | Replace     of { from_ : string; to_ : string }  (* drift errors only *)

type finding = {
  rule : Lint_rules.id;
  loc  : Token.loc;   (* the whole item for the item-level rules *)
  text : string;
  fix  : fix option;
}

let strip_located = Ast.strip_located

let ends_with s c = String.length s > 0 && s.[String.length s - 1] = c

(* Types reach here with inference variables still standing in for what was
   solved, so every read has to go through repr first. *)
let rec result_type (t : Typechecker.typ) =
  match Typechecker.repr t with
  | Typechecker.TFun (_, r, _) -> result_type r
  | t -> t

let type_of_scheme (s : Typechecker.scheme) =
  match s with
  | Typechecker.Mono t -> Some t
  | Typechecker.Poly (_, _, t) -> Some t
  | Typechecker.Namespace _ -> None

(* Any Result in the type whose error side carries nothing. *)
let rec informationless_error (t : Typechecker.typ) =
  match Typechecker.repr t with
  | Typechecker.TResult (e, _) when Typechecker.repr e = Typechecker.TUnit -> true
  | Typechecker.TResult (e, v) -> informationless_error e || informationless_error v
  | Typechecker.TFun (a, b, _) -> informationless_error a || informationless_error b
  | Typechecker.TApp (a, b) -> informationless_error a || informationless_error b
  | Typechecker.TList t | Typechecker.TMap t -> informationless_error t
  | Typechecker.TTuple ts -> List.exists informationless_error ts
  | _ -> false

(* Whether any arrow in the type can raise. A curried function's arrows share
   one effect set, so it does not matter which is asked. *)
let rec type_raises (t : Typechecker.typ) =
  match Typechecker.repr t with
  | Typechecker.TFun (a, b, r) ->
    Effect_set.mem Effect_set.Raise r || type_raises a || type_raises b
  | Typechecker.TTuple ts -> List.exists type_raises ts
  | Typechecker.TList t | Typechecker.TMap t -> type_raises t
  | Typechecker.TResult (e, t) -> type_raises e || type_raises t
  | Typechecker.TApp (f, a) -> type_raises f || type_raises a
  | _ -> false

let is_function (t : Typechecker.typ) =
  match Typechecker.repr t with Typechecker.TFun _ -> true | _ -> false

let rec pat_names (p : Ast.pat) =
  match p with
  | Ast.PVar n -> [n]
  | Ast.PTuple ps | Ast.PList ps -> List.concat_map pat_names ps
  | Ast.PCons (h, t) -> pat_names h @ pat_names t
  | Ast.PConstr (_, ps) -> List.concat_map pat_names ps
  | Ast.PConstrNamed (_, kvs) | Ast.PMap kvs ->
    List.concat_map (fun (_, p) -> pat_names p) kvs
  | Ast.PAnnot (p, _) -> pat_names p
  | _ -> []

(* Shell-level structure in a command string. One stage is exactly what $()
   is for; it is the accumulation of stages that hides work from the type
   system and from --trace. *)
let shell_operators cmd =
  let n = String.length cmd in
  let count = ref 0 and i = ref 0 in
  while !i < n do
    (match cmd.[!i] with
     | '|' when !i + 1 < n && cmd.[!i + 1] = '|' -> incr count; incr i
     | '&' when !i + 1 < n && cmd.[!i + 1] = '&' -> incr count; incr i
     | '|' | '>' | '<' | ';' -> incr count
     | _ -> ());
    incr i
  done;
  !count

let shell_threshold = 3

(* ── Traversal ───────────────────────────────────────────────────────────── *)

let walk_expr start_loc (e : Ast.expr) : finding list =
  let acc = ref [] in
  let here = ref start_loc in
  let rec go (e : Ast.expr) =
    match e with
    | Ast.Located (l, inner) ->
      let saved = !here in
      here := l; go inner; here := saved
    | Ast.RunCmd (inner, allow) | Ast.RunQuery (inner, allow) ->
      (match strip_located inner with
       | Ast.String cmd ->
         let ops = shell_operators cmd in
         if ops >= shell_threshold then
           acc := { rule = Lint_rules.A_SHELL1;
                    loc = !here;
                    text = Lint_rules.shell1 ~stages:ops;
                    fix = None } :: !acc
       | _ -> ());
      (* A narrowed manifest with a command word only the run decides:
         legal, checked at spawn, and said out loud -- under --strict this
         is what holds a file to fully static words. *)
      (if allow <> None then
         let s = Shell_scan.scan (Shell_scan.segs_of_cmd inner) in
         if s.Shell_scan.raw_tail
            || List.exists (fun w -> w = Shell_scan.Dynamic)
                 s.Shell_scan.words
         then
           acc := { rule = Lint_rules.V_SHELL1;
                    loc = !here;
                    text = Lint_rules.shell1_dynamic;
                    fix = None } :: !acc);
      go inner
    | Ast.Interp (parts, _) | Ast.RawInterp (parts, _) ->
      List.iter (fun (_, e) -> go e) parts
    | Ast.App (a, b) | Ast.BinOp (_, a, b) | Ast.Seq (a, b) -> go a; go b
    | Ast.UnOp (_, a) | Ast.Fn (_, a) | Ast.Annot (_, a)
    | Ast.Field (a, _) | Ast.Try a -> go a
    | Ast.Let (_, a, b, _) -> go a; go b
    | Ast.LetRec (bs, b, _) -> List.iter (fun (_, _, x) -> go x) bs; go b
    | Ast.If (c, t, f) -> go c; go t; go f
    | Ast.Match (s, cases) ->
      go s;
      List.iter (fun (_, g, b) ->
        (match g with Some g -> go g | None -> ()); go b) cases
    | Ast.Tuple es | Ast.List es -> List.iter go es
    | Ast.MapLit kvs -> List.iter (fun (_, v) -> go v) kvs
    | Ast.ConstrApp (_, fields) -> List.iter (fun (_, v) -> go v) fields
    | Ast.ConstrUpdate (_, base, fields) -> go base; List.iter (fun (_, v) -> go v) fields
    | Ast.Handle (b, cases) ->
      go b;
      List.iter (function
        | Ast.ReturnCase (_, x) -> go x
        | Ast.EffectCase (_, _, _, x) -> go x) cases
    | Ast.Contract (reqs, ens, body) ->
      List.iter go reqs; List.iter go ens; go body
    | _ -> ()
  in
  go e;
  List.rev !acc

(* `own_env` holds the program's own top-level bindings, already inferred, so
   the type-directed rules read what the checker concluded rather than
   re-deriving it. *)
let check (prog : Ast.program) (item_locs : (Token.loc * Token.loc) list)
    (own_env : Typechecker.env) : finding list =
  let locs = Array.of_list item_locs in
  let no_loc = Token.point 0 0 0 in
  let findings = ref [] in
  let add ?fix rule loc text =
    findings := { rule; loc; text; fix } :: !findings
  in
  (* V-IMP1 watches every import in the file, not only the leading run.
     Imports bind before the file's own bindings, wherever they are
     written, so the last import of a name decides every use of it -- a use
     above the second import line reads the second import. The earlier
     binding is dead however far down the rebinding sits.

     The rule used to stop at the first non-import item, on the reasoning
     that a later rebinding might follow a genuine use. It cannot: the
     "genuine use" reads the later module too, which is the whole reason
     this warns. Found porting a script whose helper collided with an
     earlier port's.

     The pattern can bind another name (`let {parse = csv_parse} = import
     CSV`), so keeping both is spelled by renaming, not by shadowing. *)
  let import_display = function
    | Ast.StdlibModule s -> s
    | Ast.UserPath p     -> p
  in
  let imports_seen : (string * (Token.loc * string)) list ref = ref [] in
  List.iteri (fun i (item : Ast.top_item) ->
    (* An item-level finding marks the whole item, first token to last. *)
    let loc =
      if i < Array.length locs
      then Token.span_to (fst locs.(i)) (snd locs.(i))
      else no_loc
    in
    begin
      let bound = match item with
        | Ast.TLImport _ -> Some []
        | Ast.TLLet (name, [], body) ->
          Option.map (fun k -> [ (name, k) ]) (Module_types.import_kind_of body)
        | Ast.TLLetPat (pat, body) ->
          Option.map (fun k -> List.map (fun n -> (n, k)) (pat_names pat))
            (Module_types.import_kind_of body)
        | _ -> None
      in
      match bound with
      | None -> ()
      | Some names ->
        List.iter (fun (n, k) ->
          let this = import_display k in
          (match List.assoc_opt n !imports_seen with
           | Some (first_loc, first_mod) ->
             (* The dead binding is the earlier one, so the fix deletes the
                line the finding already points at. *)
             add ~fix:DeleteLine Lint_rules.V_IMP1 first_loc
               (Lint_rules.imp1 ~name:n ~first:first_mod ~second:this
                  ~line:loc.Token.line)
           | None -> ());
          imports_seen := (n, (loc, this)) :: List.remove_assoc n !imports_seen
        ) names
    end;
    match item with
    | Ast.TLLet (name, params, body) ->
      (match Option.bind (List.assoc_opt name own_env) type_of_scheme with
       | Some t ->
         let res = result_type t in
         if ends_with name '?' && String.length name > 4
            && String.sub name 0 3 = "is_" then
           add Lint_rules.V_PRED2 loc (Lint_rules.pred2 ~name);
         if ends_with name '?' && res <> Typechecker.TBool then
           add Lint_rules.V_PRED1 loc
             (Lint_rules.pred1 ~name ~actual:(Typechecker.string_of_typ res));
         if informationless_error t then
           add Lint_rules.V_OR1 loc (Lint_rules.or1 ~name);
         (* The `!` convention, checked in both directions now that a
            signature says whether a function can raise. *)
         if is_function t then begin
           let raises = type_raises t in
           if raises && not (ends_with name '!') then
             add Lint_rules.V_BANG1 loc (Lint_rules.bang1 ~name);
           if (not raises) && ends_with name '!' then
             add Lint_rules.V_BANG2 loc (Lint_rules.bang2 ~name)
         end
       | None -> ());
      (match List.concat_map pat_names params
             |> List.filter (fun n -> String.length n > 1 && ends_with n '_') with
       | [] -> ()
       | ps -> add Lint_rules.V_NAME1 loc (Lint_rules.name1 ~name ~params:ps));
      findings := List.rev_append (walk_expr loc body) !findings
    | Ast.TLExpr body ->
      (* A statement whose value is a Result throws away the failure it
         carries, and nothing else reports it: `wand t` is happy, the script
         exits 0, and the write that did not happen is never mentioned.
         Only Results, because discarding a String is what running a command
         for its effect looks like. The last item is the file's value rather
         than a discarded one, so it is left alone.

         `let () = ...` already catches this as a type error, and `let _ =`
         says the failure does not matter. This is for the bare statement,
         which says nothing either way. *)
      (if i < List.length prog.Ast.items - 1 then
         match List.assoc_opt i !Typechecker.expr_item_types with
         | Some t ->
           (match Typechecker.repr t with
            | Typechecker.TResult _ ->
              add Lint_rules.V_DROP1 loc
                (Lint_rules.drop1 ~typ:(Typechecker.string_of_typ t))
            | _ -> ())
         | None -> ());
      findings := List.rev_append (walk_expr loc body) !findings
    | Ast.TLLetPat (_, body) ->
      findings := List.rev_append (walk_expr loc body) !findings
    | Ast.TLLetRec bindings ->
      List.iter (fun (_, _, b) ->
        findings := List.rev_append (walk_expr loc b) !findings) bindings
    | Ast.TLImport _ | Ast.TLType _ -> ()
  ) prog.Ast.items;
  (* The same rule for `(e1; e2)` sequences: every expression before the
     last is discarded, and one whose value is a Result throws away the
     failure it carries. Recorded by the typechecker because the rule needs
     the type, exactly like the bare-statement case above.

     A discarded TestOutcome is the same mistake with a worse ending, so it
     is checked here too. Only in a sequence: a test file's top-level
     `test "..."` statements are collected by the runner, so discarding one
     there is how the framework is meant to be used. *)
  List.iter (fun (loc, t) ->
    match Typechecker.repr t with
    | Typechecker.TResult _ ->
      add Lint_rules.V_DROP1 loc
        (Lint_rules.drop1 ~typ:(Typechecker.string_of_typ t))
    | Typechecker.TName "TestOutcome" ->
      add Lint_rules.V_DROP2 loc Lint_rules.drop2
    | _ -> ()) !Typechecker.seq_discard_types;
  (* A manifest that permits more than the file uses. Checked from what
     inference concluded, so the rule cannot disagree with the type error
     that covers the opposite case. *)
  (match !Typechecker.last_manifest with
   | Some (declared, inferred, loc) ->
     let unused = Effect_set.EffSet.diff declared inferred in
     if not (Effect_set.EffSet.is_empty unused) then begin
       let corrected =
         if Effect_set.EffSet.is_empty inferred then None
         else
           Some (Typechecker.render_manifest
                   ?shell:(Typechecker.shell_suggestion ()) inferred)
       in
       add ?fix:(Option.map (fun c -> ReplaceLine c) corrected)
         Lint_rules.A_USES1 loc
         (Lint_rules.uses1
            ~unused:(String.concat ", "
              (List.map Effect_set.name_of (Effect_set.EffSet.elements unused)))
            ~corrected)
     end
     else begin
       (* The labels all earn their place; do the binaries? Only judged
          when every command position is literal -- an interpolated one may
          be exactly where the unused-looking binary is spawned. *)
       match !Typechecker.last_shell_allow with
       | Some allow when !Typechecker.last_shell_static ->
         let used = !Typechecker.last_shell_words in
         let unused_bins =
           List.filter (fun entry ->
             not (List.exists (Shell_scan.allowed ~allow:[entry]) used))
             allow
         in
         if unused_bins <> [] then begin
           let kept =
             List.filter (fun e -> not (List.mem e unused_bins)) allow in
           let corrected =
             Typechecker.render_manifest
               ?shell:(if kept = [] then None else Some kept) inferred
           in
           add ~fix:(ReplaceLine corrected) Lint_rules.A_USES1 loc
             (Lint_rules.uses1_shell
                ~unused:(String.concat ", "
                  (List.map (fun b -> "'" ^ b ^ "'") unused_bins))
                ~corrected)
         end
       | _ -> ()
     end
   | None ->
     (* No manifest at all. A file that reaches outside itself is told what
        it could declare; a file that does not has nothing to say. *)
     let performs = !Typechecker.last_file_effects in
     if not (Effect_set.EffSet.is_empty performs) then
       let corrected =
         Typechecker.render_manifest
           ?shell:(Typechecker.shell_suggestion ()) performs in
       add ~fix:(InsertLine corrected)
         Lint_rules.A_USES2 (Token.point 1 1 0)
         (Lint_rules.uses2
            ~performs:(String.concat ", "
              (List.map Effect_set.name_of (Effect_set.EffSet.elements performs)))
            ~corrected));
  List.stable_sort (fun a b ->
    match compare a.loc.Token.line b.loc.Token.line with
    | 0 -> compare a.loc.Token.col b.loc.Token.col
    | c -> c)
    (List.rev !findings)

(* ── Rendering ───────────────────────────────────────────────────────────── *)

(* Only must-fix rules can fail a build. *)
let fails_strict f = Lint_rules.kind f.rule = Lint_rules.Violation

let to_text f =
  Printf.sprintf "%d:%d: %s: %s" f.loc.Token.line f.loc.Token.col
    (Lint_rules.code f.rule) f.text

let contains = Diag.contains

(* ── Structured diagnostics (`wand t --json`) ────────────────────────────── *)

(* One JSON array on stdout, one object per diagnostic, rendered by `Diag`.
   The schema is part of the CLI's contract (reference.md, "REPL and CLI"):
   every object has `severity`, `code`, `line`, `col`, and `message`; `file`
   when a file was named; a `fix` object when a machine-applicable
   correction exists; and typed holes come as their own `{"kind":"hole"}`
   shape. *)

let to_diag ~strict f : Diag.t =
  { Diag.severity = if strict && fails_strict f then Diag.Error else Diag.Warning;
    code    = Lint_rules.code f.rule;
    loc     = Some f.loc;
    message = f.text;
    fix     = f.fix }

let hole_json t =
  Printf.sprintf "{\"kind\":\"hole\",\"type\":\"%s\"}" (Diag.escape_json t)

let diagnostics_json ~strict ?file ~holes findings =
  "[" ^ String.concat ","
    (List.map hole_json holes
     @ List.map (fun f -> Diag.to_json ?file (to_diag ~strict f)) findings)
  ^ "]"

let to_json fs = diagnostics_json ~strict:false ~holes:[] fs
