(* Lints run inside `wand t` rather than as a separate command: the typecheck
   is the step an editing loop already repeats, and a rule that does not
   surface there is a rule its audience never sees.

   This module only finds violations and locates them. What each rule is
   called, how it is classified, and what it says all live in `Lint_rules`. *)

(* A machine-applicable correction, carried alongside the human text so a
   tool consuming `--json` can fix without re-parsing prose. *)
type fix =
  | InsertLine  of string   (* a line the file lacks (the manifest) *)
  | ReplaceLine of string   (* the corrected form of the flagged line *)

type finding = {
  rule : Lint_rules.id;
  line : int;
  col  : int;
  text : string;
  fix  : fix option;
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
    | Ast.RunCmd (inner, allow) | Ast.RunQuery (inner, allow) ->
      (match strip_located inner with
       | Ast.String cmd ->
         let ops = shell_operators cmd in
         if ops >= shell_threshold then
           acc := { rule = Lint_rules.A_SHELL1;
                    line = (!here).Token.line; col = (!here).Token.col;
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
                    line = (!here).Token.line; col = (!here).Token.col;
                    text = Lint_rules.shell1_dynamic;
                    fix = None } :: !acc);
      go inner
    | Ast.Interp (parts, _) | Ast.RawInterp (parts, _) ->
      List.iter (fun (_, e) -> go e) parts
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
  let add ?fix rule loc text =
    findings :=
      { rule; line = loc.Token.line; col = loc.Token.col; text; fix } :: !findings
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
  (* The same rule for `(e1; e2)` sequences: every expression before the
     last is discarded, and one whose value is a Result throws away the
     failure it carries. Recorded by the typechecker because the rule needs
     the type, exactly like the bare-statement case above. *)
  List.iter (fun (loc, t) ->
    match Typechecker.repr t with
    | Typechecker.TResult _ ->
      add Lint_rules.V_DROP1 loc
        (Lint_rules.drop1 ~typ:(Typechecker.string_of_typ t))
    | _ -> ()) !Typechecker.seq_discard_types;
  (* A manifest that permits more than the file uses. Checked from what
     inference concluded, so the rule cannot disagree with the type error
     that covers the opposite case. *)
  (match !Typechecker.last_manifest with
   | Some (declared, inferred, loc) ->
     let unused = Effect_row.EffSet.diff declared inferred in
     if not (Effect_row.EffSet.is_empty unused) then begin
       let corrected =
         if Effect_row.EffSet.is_empty inferred then None
         else
           Some (Typechecker.render_manifest
                   ?shell:(Typechecker.shell_suggestion ()) inferred)
       in
       add ?fix:(Option.map (fun c -> ReplaceLine c) corrected)
         Lint_rules.A_USES1 loc
         (Lint_rules.uses1
            ~unused:(String.concat ", "
              (List.map Effect_row.name_of (Effect_row.EffSet.elements unused)))
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
     if not (Effect_row.EffSet.is_empty performs) then
       let corrected =
         Typechecker.render_manifest
           ?shell:(Typechecker.shell_suggestion ()) performs in
       add ~fix:(InsertLine corrected)
         Lint_rules.A_USES2 { Token.line = 1; col = 1; offset = 0 }
         (Lint_rules.uses2
            ~performs:(String.concat ", "
              (List.map Effect_row.name_of (Effect_row.EffSet.elements performs)))
            ~corrected));
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

(* ── Structured diagnostics (`wand t --json`) ────────────────────────────── *)

(* One JSON array on stdout, one object per diagnostic. The schema is part
   of the CLI's contract (reference.md, "REPL and CLI"): every object has
   `severity`, `code`, `line`, `col`, and `message`; `file` when a file was
   named; a `fix` object when a machine-applicable correction exists; and
   typed holes come as their own `{"kind":"hole"}` shape. *)

let contains msg needle =
  let n = String.length needle and m = String.length msg in
  let rec go i = i + n <= m && (String.sub msg i n = needle || go (i + 1)) in
  go 0

let fix_json = function
  | InsertLine l  -> Printf.sprintf "{\"insert_line\":\"%s\"}" (escape_json l)
  | ReplaceLine l -> Printf.sprintf "{\"replace_line\":\"%s\"}" (escape_json l)

let file_field = function
  | None -> ""
  | Some f -> Printf.sprintf "\"file\":\"%s\"," (escape_json f)

let finding_json ~strict ?file f =
  let severity = if strict && fails_strict f then "error" else "warning" in
  Printf.sprintf
    "{\"severity\":\"%s\",\"code\":\"%s\",%s\"line\":%d,\"col\":%d,\"message\":\"%s\"%s}"
    severity (Lint_rules.code f.rule) (file_field file) f.line f.col
    (escape_json f.text)
    (match f.fix with None -> "" | Some fx -> ",\"fix\":" ^ fix_json fx)

let hole_json t =
  Printf.sprintf "{\"kind\":\"hole\",\"type\":\"%s\"}" (escape_json t)

(* The drift errors name their correction in prose; where the correction is
   a plain textual substitution, carry it as data too. Keyed on fragments
   test_drift.ml locks, so rewording a message that breaks a key breaks a
   test alongside it. *)
let drift_fixes = [
  "cons is a single ':' in wand", ("::", ":");
  "not '//'",                     ("//", "--");
  "not '# ...'",                  ("#", "--");
  "not ${...}",                   ("${", "%{");
  "not #{...}",                   ("#{", "%{");
  "drop the 'rec'",               ("let rec", "let");
  "not '^'",                      ("^", "++");
  "boolean operator is '&&'",     ("and", "&&");
  "boolean operator is '||'",     ("or", "||");
  "boolean not is '!'",           ("not", "!");
]

let error_fix_json msg =
  match List.find_opt (fun (frag, _) -> contains msg frag) drift_fixes with
  | None -> ""
  | Some (_, (from_, to_)) ->
    Printf.sprintf ",\"fix\":{\"replace\":{\"from\":\"%s\",\"to\":\"%s\"}}"
      (escape_json from_) (escape_json to_)

(* An error message arrives as "<label>: [line:col: ] text". The label
   becomes a stable code, the position is lifted out when present. *)
let error_json ?file msg =
  let starts p = String.length msg >= String.length p
                 && String.sub msg 0 (String.length p) = p in
  let (code, rest) =
    if starts "type error: " then ("E-TYPE", String.sub msg 12 (String.length msg - 12))
    else if starts "parse error: " then ("E-PARSE", String.sub msg 13 (String.length msg - 13))
    else if starts "lex error: " then ("E-LEX", String.sub msg 11 (String.length msg - 11))
    else ("E-FAIL", msg)
  in
  let (line, col, text) =
    match String.index_opt rest ' ' with
    | Some sp ->
      (try Scanf.sscanf (String.sub rest 0 sp) "%d:%d:"
             (fun l c -> (l, c, String.sub rest (sp + 1) (String.length rest - sp - 1)))
       with Scanf.Scan_failure _ | Failure _ | End_of_file -> (1, 1, rest))
    | None -> (1, 1, rest)
  in
  Printf.sprintf
    "{\"severity\":\"error\",\"code\":\"%s\",%s\"line\":%d,\"col\":%d,\"message\":\"%s\"%s}"
    code (file_field file) line col (escape_json text) (error_fix_json text)

let diagnostics_json ~strict ?file ~holes findings =
  "[" ^ String.concat ","
    (List.map hole_json holes
     @ List.map (finding_json ~strict ?file) findings)
  ^ "]"

let error_to_json ?file msg = "[" ^ error_json ?file msg ^ "]"

let to_json fs = diagnostics_json ~strict:false ~holes:[] fs
