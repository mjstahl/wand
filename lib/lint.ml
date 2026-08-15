(* Lints run inside `wand t` rather than as a separate command: the typecheck
   is the step an editing loop already repeats, and a rule that does not
   surface there is a rule its audience never sees.

   This module only finds violations and locates them. What each rule is
   called, how it is classified, and what it says all live in `Lint_rules`. *)

type finding = {
  rule : Lint_rules.id;
  line : int;
  col  : int;
  text : string;
}

let rec strip_located e =
  match e with
  | Ast.Located (_, x) -> strip_located x
  | x -> x

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
   one row, so it does not matter which is asked. *)
let rec type_raises (t : Typechecker.typ) =
  match Typechecker.repr t with
  | Typechecker.TFun (a, b, r) ->
    Effect_row.mem Effect_row.Raise r || type_raises a || type_raises b
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
    | Ast.RunCmd inner | Ast.RunQuery inner ->
      (match strip_located inner with
       | Ast.String cmd ->
         let ops = shell_operators cmd in
         if ops >= shell_threshold then
           acc := { rule = Lint_rules.A_SHELL1;
                    line = (!here).Token.line; col = (!here).Token.col;
                    text = Lint_rules.shell1 ~stages:ops } :: !acc
       | _ -> ());
      go inner
    | Ast.Interp (parts, _) -> List.iter (fun (_, e) -> go e) parts
    | Ast.App (a, b) | Ast.BinOp (_, a, b) | Ast.Seq (a, b) -> go a; go b
    | Ast.UnOp (_, a) | Ast.Fn (_, a) | Ast.Annot (_, a)
    | Ast.Field (a, _) | Ast.Try a -> go a
    | Ast.Let (_, a, b) -> go a; go b
    | Ast.LetRec (bs, b) -> List.iter (fun (_, _, x) -> go x) bs; go b
    | Ast.If (c, t, f) -> go c; go t; go f
    | Ast.Match (s, cases) ->
      go s;
      List.iter (fun (_, g, b) ->
        (match g with Some g -> go g | None -> ()); go b) cases
    | Ast.Tuple es | Ast.List es -> List.iter go es
    | Ast.MapLit kvs -> List.iter (fun (_, v) -> go v) kvs
    | Ast.ConstrApp (_, fields) -> List.iter (fun (_, v) -> go v) fields
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
  let no_loc = Token.{ line = 0; col = 0; offset = 0 } in
  let findings = ref [] in
  let add rule loc text =
    findings := { rule; line = loc.Token.line; col = loc.Token.col; text } :: !findings
  in
  List.iteri (fun i (item : Ast.top_item) ->
    let loc = if i < Array.length locs then fst locs.(i) else no_loc in
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
  (* A manifest that permits more than the file uses. Checked from what
     inference concluded, so the rule cannot disagree with the type error
     that covers the opposite case. *)
  (match !Typechecker.last_manifest with
   | Some (declared, inferred, loc) ->
     let unused = Effect_row.EffSet.diff declared inferred in
     if not (Effect_row.EffSet.is_empty unused) then
       add Lint_rules.A_USES1 loc
         (Lint_rules.uses1
            ~unused:(String.concat ", "
              (List.map Effect_row.name_of (Effect_row.EffSet.elements unused)))
            ~corrected:(if Effect_row.EffSet.is_empty inferred then None
                        else Some (Typechecker.render_manifest inferred)))
   | None ->
     (* No manifest at all. A file that reaches outside itself is told what
        it could declare; a file that does not has nothing to say. *)
     let performs = !Typechecker.last_file_effects in
     if not (Effect_row.EffSet.is_empty performs) then
       add Lint_rules.A_USES2 { Token.line = 1; col = 1; offset = 0 }
         (Lint_rules.uses2
            ~performs:(String.concat ", "
              (List.map Effect_row.name_of (Effect_row.EffSet.elements performs)))
            ~corrected:(Typechecker.render_manifest performs)));
  List.stable_sort (fun a b ->
    match compare a.line b.line with 0 -> compare a.col b.col | c -> c)
    (List.rev !findings)

(* ── Rendering ───────────────────────────────────────────────────────────── *)

(* Only must-fix rules can fail a build. *)
let fails_strict f = Lint_rules.kind f.rule = Lint_rules.Violation

let to_text f =
  Printf.sprintf "%d:%d: %s: %s" f.line f.col (Lint_rules.code f.rule) f.text

let escape_json s =
  let buf = Buffer.create (String.length s + 8) in
  String.iter (fun c ->
    match c with
    | '"'  -> Buffer.add_string buf "\\\""
    | '\\' -> Buffer.add_string buf "\\\\"
    | '\n' -> Buffer.add_string buf "\\n"
    | '\t' -> Buffer.add_string buf "\\t"
    | c when Char.code c < 0x20 ->
      Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
    | c -> Buffer.add_char buf c) s;
  Buffer.contents buf

let to_json fs =
  "[" ^ String.concat ","
    (List.map (fun f ->
       Printf.sprintf
         "{\"rule\":\"%s\",\"kind\":\"%s\",\"line\":%d,\"col\":%d,\"message\":\"%s\"}"
         (Lint_rules.code f.rule)
         (Lint_rules.kind_name (Lint_rules.kind f.rule))
         f.line f.col (escape_json f.text)) fs)
  ^ "]"
