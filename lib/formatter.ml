open Ast

(* ── Small helpers ────────────────────────────────────────────────────────── *)

let max_width = 92

let fits indent s =
  not (String.contains s '\n') && indent + String.length s <= max_width

let rec strip_located e = match e with
  | Located (_, e) -> strip_located e
  | e -> e

let escape_string_body str =
  let n = String.length str in
  let buf = Buffer.create (n + 8) in
  String.iteri (fun i c ->
    match c with
    | '\\' -> Buffer.add_string buf "\\\\"
    | '"'  -> Buffer.add_string buf "\\\""
    | '\n' -> Buffer.add_string buf "\\n"
    | '\t' -> Buffer.add_string buf "\\t"
    | '\r' -> Buffer.add_string buf "\\r"
    | '$' when i + 1 < n && (str.[i + 1] = '{'
               || (str.[i + 1] >= 'A' && str.[i + 1] <= 'Z')) ->
      Buffer.add_string buf "\\$"
    | c -> Buffer.add_char buf c
  ) str;
  Buffer.contents buf

(* ── Follow-up-tier detection (verbatim-fallback trigger) ───────────────────
   Contract/Handle/RunCmd/RunQuery/Try/RegexLit are rare in practice (see
   plan) and aren't given a real formatting rule in v1 -- any top-item that
   contains one anywhere is re-emitted as a verbatim source slice instead. *)
let rec expr_has_followup e =
  match strip_located e with
  | Contract _ | Handle _ | RunCmd _ | RunQuery _ | Try _ | RegexLit _ -> true
  | Int _ | Float _ | String _ | Bool _ | Unit | Path _ | Glob _ | Date _
  | Time _ | DateTime _ | Duration _ | Url _ | IPv4 _ | CIDR _ | Port _
  | Version _ | Size _ | Var _ | Constr _ | EnvVar _ | Hole
  | ImportExpr _ -> false
  | App (f, x) -> expr_has_followup f || expr_has_followup x
  | Fn (_, b) -> expr_has_followup b
  | Let (_, e1, e2) -> expr_has_followup e1 || expr_has_followup e2
  | LetRec (bindings, e2) ->
    List.exists (fun (_, _, b) -> expr_has_followup b) bindings || expr_has_followup e2
  | If (c, t, e) -> expr_has_followup c || expr_has_followup t || expr_has_followup e
  | Match (scr, cases) ->
    expr_has_followup scr ||
    List.exists (fun (_, g, b) ->
      (match g with Some g -> expr_has_followup g | None -> false) || expr_has_followup b
    ) cases
  | BinOp (_, a, b) -> expr_has_followup a || expr_has_followup b
  | UnOp (_, e) -> expr_has_followup e
  | Tuple es | List es -> List.exists expr_has_followup es
  | ConstrApp (_, kvs) -> List.exists (fun (_, v) -> expr_has_followup v) kvs
  | Field (e, _) -> expr_has_followup e
  | Seq (a, b) -> expr_has_followup a || expr_has_followup b
  | Located _ -> false (* stripped above *)
  | Interp (parts, _) -> List.exists (fun (_, e) -> expr_has_followup e) parts
  | Annot (_, e) -> expr_has_followup e
  | MapLit kvs -> List.exists (fun (_, v) -> expr_has_followup v) kvs

let top_item_has_followup = function
  | TLLet (_, _, e) -> expr_has_followup e
  | TLLetRec bindings -> List.exists (fun (_, _, b) -> expr_has_followup b) bindings
  | TLLetPat (_, e) -> expr_has_followup e
  | TLImport _ | TLType _ -> false
  | TLExpr e -> expr_has_followup e

(* ── Type expressions ────────────────────────────────────────────────────── *)

let rec emit_type_expr te = match te with
  | TEFun (a, b) -> emit_type_operand a ^ " -> " ^ emit_type_expr b
  | _ -> emit_type_app_expr te
and emit_type_operand te = match te with
  | TEFun _ -> "(" ^ emit_type_expr te ^ ")"
  | _ -> emit_type_expr te
and emit_type_app_expr te = match te with
  | TEApp (f, a) -> emit_type_app_expr f ^ " " ^ emit_type_atom a
  | _ -> emit_type_atom te
and emit_type_atom te = match te with
  | TEName n -> n
  | TEVar v -> "'" ^ v
  | TETuple ts -> "(" ^ String.concat ", " (List.map emit_type_expr ts) ^ ")"
  | TEApp _ | TEFun _ -> "(" ^ emit_type_expr te ^ ")"

(* ── Patterns ─────────────────────────────────────────────────────────────── *)

let rec emit_pat (p : pat) : string = match p with
  | Int n      -> string_of_int n
  | Float f    -> Printf.sprintf "%g" f
  | String s   -> "\"" ^ escape_string_body s ^ "\""
  | Bool b     -> string_of_bool b
  | Unit       -> "()"
  | Path s | Date s | Time s | DateTime s | Duration s
  | Url s | CIDR s | Version s | Size s | IPv4 s -> s
  | Port n     -> ":" ^ string_of_int n
  | PVar x     -> x
  | Wild       -> "_"
  | PTuple ps  -> "(" ^ String.concat ", " (List.map emit_pat ps) ^ ")"
  | PList ps   -> "[" ^ String.concat ", " (List.map emit_pat ps) ^ "]"
  | PCons (h, t) -> emit_cons_chain h t
  | PConstr (c, []) -> c
  | PConstr (c, ps) -> c ^ " " ^ String.concat " " (List.map emit_pat_atom ps)
  | PConstrNamed (c, kvs) ->
    c ^ "(" ^ String.concat ", " (List.map (fun (k, p) -> k ^ " = " ^ emit_pat p) kvs) ^ ")"
  | PMap kvs ->
    "[" ^ String.concat ", " (List.map (fun (k, p) -> k ^ " = " ^ emit_pat p) kvs) ^ "]"

and emit_pat_atom (p : pat) : string = match p with
  | PConstr (_, _ :: _) | PConstrNamed _ -> "(" ^ emit_pat p ^ ")"
  | _ -> emit_pat p

and emit_cons_chain (h : pat) (t : pat) : string =
  let rec collect acc (p : pat) : pat list * pat = match p with
    | PCons (h2, t2) -> collect (h2 :: acc) t2
    | _ -> (List.rev acc, p)
  in
  let (elems, tail) = collect [h] t in
  "[" ^ String.concat " : " (List.map emit_pat elems) ^ " : " ^ emit_pat tail ^ "]"

(* ── Multi-equation reconstruction ────────────────────────────────────────────
   `let f p1 = e1 / let f p2 = e2` desugars (parser.ml's collapse/build_
   multi_equation) into one binding whose params are synthetic `_p0.._pN`
   and whose body is a `Match` over those synthetic vars with one arm per
   original clause (guard-free). That exact, deterministic shape is
   detected here and turned back into separate per-clause equations,
   rather than always rendering the desugared match form. *)
let try_multi_equation (params : pat list) (body : expr) : (pat list * expr) list option =
  let n = List.length params in
  let synthetic_names = List.init n (fun i -> Printf.sprintf "_p%d" i) in
  let params_match =
    n > 0 &&
    List.for_all2 (fun p name -> match p with PVar v -> v = name | _ -> false)
      params synthetic_names
  in
  if not params_match then None
  else match strip_located body with
    | Match (scrutinee, arms) when List.length arms > 1 ->
      let scrutinee_ok = match n, scrutinee with
        | 1, Var v -> v = "_p0"
        | _, Tuple vs ->
          List.length vs = n &&
          List.for_all2 (fun v name -> match strip_located v with
            | Var v -> v = name | _ -> false) vs synthetic_names
        | _ -> false
      in
      if not scrutinee_ok then None
      else if not (List.for_all (fun (_, g, _) -> g = None) arms) then None
      else
        let clauses = List.map (fun (p, _, b) ->
          match n, p with
          | 1, p -> Some ([p], b)
          | _, PTuple ps when List.length ps = n -> Some (ps, b)
          | _ -> None
        ) arms in
        if List.exists (fun c -> c = None) clauses then None
        else Some (List.map (fun c -> Option.get c) clauses)
    | _ -> None

(* ── Expressions ──────────────────────────────────────────────────────────── *)

let bin_prec = function
  | "|>" -> 10 | ":" -> 15 | "||" -> 20 | "&&" -> 30
  | "==" | "!=" | "<" | ">" | "<=" | ">=" -> 40
  | "+" | "-" | "++" -> 50
  | "*" | "/" | "%" -> 60
  | _ -> 0

let bin_right_assoc = function ":" -> true | _ -> false

let is_control_expr e = match strip_located e with
  | Let _ | LetRec _ | If _ | Match _ | Fn _ | Handle _ | Try _ | Contract _ -> true
  | _ -> false

let is_binop_or_unop e = match strip_located e with
  | BinOp _ | UnOp _ -> true
  | _ -> false

(* A nested `App` used as another App's argument/target must be wrapped --
   without parens, juxtaposition would flatten it into the outer call's
   argument list instead of nesting it (`f (g x) y` vs `f g x y`). *)
let is_app e = match strip_located e with
  | App _ -> true
  | _ -> false

let rec emit_expr indent e = emit_expr_inner indent (strip_located e)

(* App-chain function/argument positions require strict "atom" syntax --
   a bare BinOp/UnOp/If/Match/Fn/Let there would be reparsed differently
   (or rejected outright), so always parenthesize those; everything else
   (literals, Var, Field, another App, Tuple/List/MapLit, ...) is already
   safe unwrapped in that position. *)
and emit_atom indent e =
  let e' = strip_located e in
  let s = emit_expr_inner indent e' in
  if is_control_expr e' || is_binop_or_unop e' || is_app e' then "(" ^ s ^ ")" else s

and emit_expr_inner indent e =
  match e with
  | Int n      -> string_of_int n
  | Float f    -> Printf.sprintf "%g" f
  | String s   -> "\"" ^ escape_string_body s ^ "\""
  | Bool b     -> string_of_bool b
  | Unit       -> "()"
  | Path s | Glob s | Date s | Time s | DateTime s | Duration s
  | Url s | CIDR s | Version s | Size s | IPv4 s -> s
  | Port n     -> ":" ^ string_of_int n
  | Var x      -> x
  | Constr x   -> x
  | EnvVar x   -> "$" ^ x
  | Hole       -> "?"
  | App _      -> emit_app indent e
  | Fn (ps, body) ->
    "fn " ^ String.concat " " (List.map emit_pat ps) ^ " -> " ^ emit_expr indent body
  | Let (p, e1, e2) -> emit_let indent p e1 e2
  | LetRec (bindings, e2) -> emit_letrec indent bindings e2
  | If (c, t, el) -> emit_if indent c t el
  | Match (scr, cases) -> emit_match indent scr cases
  | BinOp (op, a, b) -> emit_binop indent op a b
  | UnOp (op, e) -> op ^ emit_atom indent e
  | Tuple es -> "(" ^ String.concat ", " (List.map (emit_expr indent) es) ^ ")"
  | List es  -> "[" ^ String.concat ", " (List.map (emit_expr indent) es) ^ "]"
  | ConstrApp (name, kvs) ->
    name ^ "(" ^ String.concat ", " (List.map (fun (k, v) ->
      (match k with Some n -> n ^ " = " | None -> "") ^ emit_expr indent v) kvs) ^ ")"
  | Field (e, l) -> emit_field indent e l
  | Seq (a, b) ->
    let ind = String.make indent ' ' in
    emit_expr indent a ^ "\n" ^ ind ^ emit_expr indent b
  | Located (_, e) -> emit_expr_inner indent e
  | Contract (reqs, ens, body) ->
    let clause kw e = kw ^ " " ^ emit_expr indent e in
    String.concat "\n" (List.map (clause "requires") reqs @ List.map (clause "ensures") ens)
    ^ (if reqs = [] && ens = [] then "" else "\n" ^ String.make indent ' ')
    ^ emit_expr indent body
  | RunCmd e   -> "$(" ^ emit_expr indent e ^ ")"
  | RunQuery e -> "$?(" ^ emit_expr indent e ^ ")"
  | RegexLit (p, f) -> "r/" ^ p ^ "/" ^ f
  | ImportExpr (StdlibModule n) -> "import " ^ n
  | ImportExpr (UserPath p)     -> "import " ^ p
  | Interp (parts, tail) ->
    let buf = Buffer.create 32 in
    Buffer.add_char buf '"';
    List.iter (fun (lit, e) ->
      Buffer.add_string buf (escape_string_body lit);
      Buffer.add_string buf "${";
      Buffer.add_string buf (emit_expr indent e);
      Buffer.add_char buf '}'
    ) parts;
    Buffer.add_string buf (escape_string_body tail);
    Buffer.add_char buf '"';
    Buffer.contents buf
  | Handle (body, arms) ->
    let emit_arm = function
      | EffectArm (op, p, k, b) ->
        Printf.sprintf "| %s %s %s -> %s" op (emit_pat p) k (emit_expr indent b)
      | ReturnArm (p, b) ->
        Printf.sprintf "| return %s -> %s" (emit_pat p) (emit_expr indent b)
    in
    "handle " ^ emit_expr indent body ^ " with\n"
    ^ String.make indent ' ' ^ String.concat ("\n" ^ String.make indent ' ')
        (List.map emit_arm arms)
  | Try e -> "try " ^ emit_expr indent e
  | Annot (te, e) -> emit_atom indent e ^ " : " ^ emit_type_expr te
  | MapLit kvs ->
    "[" ^ String.concat ", " (List.map (fun (k, e) -> k ^ " = " ^ emit_expr indent e) kvs) ^ "]"

and emit_app indent e =
  let rec flatten e = match strip_located e with
    | App (f, x) -> let (h, args) = flatten f in (h, args @ [x])
    | other -> (other, [])
  in
  let (head, args) = flatten e in
  if args = [] then emit_expr indent head
  else emit_atom indent head ^ " " ^ String.concat " " (List.map (emit_atom indent) args)

and emit_field indent e l =
  let e' = strip_located e in
  let target = match e' with
    | BinOp _ | UnOp _ | Let _ | LetRec _ | If _ | Match _ | Fn _
    | Handle _ | Try _ | Contract _ -> "(" ^ emit_expr indent e' ^ ")"
    | _ -> emit_expr indent e'
  in
  target ^ "." ^ l

and emit_binop indent op a b =
  let prec = bin_prec op in
  let assoc = if bin_right_assoc op then `Right else `Left in
  let side_str side e =
    match strip_located e with
    | BinOp (op2, a2, b2) ->
      let cp = bin_prec op2 in
      let ok = cp > prec || (cp = prec && (match side with
        | `Left -> assoc = `Left | `Right -> assoc = `Right)) in
      let inner = emit_binop indent op2 a2 b2 in
      if ok then inner else "(" ^ inner ^ ")"
    | _ -> emit_expr indent e
  in
  Printf.sprintf "%s %s %s" (side_str `Left a) op (side_str `Right b)

and emit_let indent p e1 e2 =
  match strip_located e1 with
  | Fn (params, fbody) when (match try_multi_equation params fbody with Some _ -> true | None -> false) ->
    let clauses = Option.get (try_multi_equation params fbody) in
    let name = match p with PVar n -> n | _ -> "_" in
    let ind = String.make indent ' ' in
    let lines = List.mapi (fun i (pats, body) ->
      let kw = if i = 0 then "let " ^ name else name in
      let head = kw ^ " " ^ String.concat " " (List.map emit_pat pats) in
      let oneline = head ^ " = " ^ emit_expr indent body in
      if fits indent oneline then oneline
      else head ^ " =\n" ^ ind ^ "  " ^ emit_expr (indent + 2) body
    ) clauses in
    String.concat ("\n" ^ ind) lines ^ "\n" ^ ind ^ "in " ^ emit_expr indent e2
  | _ ->
  let e1s = emit_expr indent e1 and e2s = emit_expr indent e2 in
  let oneline = Printf.sprintf "let %s = %s in %s" (emit_pat p) e1s e2s in
  if fits indent oneline then oneline
  else
    let ind = String.make indent ' ' in
    Printf.sprintf "let %s = %s in\n%s%s" (emit_pat p) e1s ind e2s

and emit_letrec indent bindings e2 =
  let emit_binding kw (name, params, body) =
    kw ^ " " ^ name
    ^ (if params = [] then "" else " " ^ String.concat " " (List.map emit_pat params))
    ^ " = " ^ emit_expr indent body
  in
  let ind = String.make indent ' ' in
  let lines = match bindings with
    | [] -> []
    | first :: rest ->
      emit_binding "let" first :: List.map (emit_binding "and") rest
  in
  String.concat ("\n" ^ ind) lines ^ "\n" ^ ind ^ "in " ^ emit_expr indent e2

and emit_if indent c t el =
  let cs = emit_expr indent c and ts = emit_expr indent t and es = emit_expr indent el in
  let oneline = Printf.sprintf "if %s then %s else %s" cs ts es in
  if fits indent oneline then oneline
  else
    let ind = String.make indent ' ' in
    Printf.sprintf "if %s then %s\n%selse %s" cs ts ind es

and emit_match indent scr cases =
  let ind = String.make indent ' ' in
  let emit_case (p, guard, body) =
    let guard_s = match guard with
      | None -> ""
      | Some g -> " when " ^ emit_expr indent g
    in
    ind ^ "| " ^ emit_pat p ^ guard_s ^ " -> " ^ emit_expr indent body
  in
  "match " ^ emit_expr indent scr ^ " with\n"
  ^ String.concat "\n" (List.map emit_case cases)

let emit_one_equation head_kw pats body =
  let head = head_kw ^ " " ^ String.concat " " (List.map emit_pat pats) in
  let oneline = head ^ " = " ^ emit_expr 0 body in
  if fits 0 oneline then oneline
  else head ^ " =\n  " ^ emit_expr 2 body

(* ── Type definitions ─────────────────────────────────────────────────────── *)

let emit_ctor_fields fields =
  if fields = [] then ""
  else match fields with
    | (Some _, _) :: _ ->
      "(" ^ String.concat ", " (List.map (fun (n, t) ->
        Option.get n ^ ": " ^ emit_type_atom t) fields) ^ ")"
    | _ ->
      " " ^ String.concat " " (List.map (fun (_, t) -> emit_type_atom t) fields)

let emit_type_def (Variants (name, params, ctors)) =
  "type " ^ name
  ^ (if params = [] then "" else " " ^ String.concat " " (List.map (fun p -> "'" ^ p) params))
  ^ " = "
  ^ String.concat " | " (List.map (fun c -> c.name ^ emit_ctor_fields c.fields) ctors)

(* ── Top-level items ──────────────────────────────────────────────────────── *)

let emit_top_item_pretty = function
  | TLImport (StdlibModule n) -> "import " ^ n
  | TLImport (UserPath p)     -> "import " ^ p
  | TLType tdef -> emit_type_def tdef
  | TLLetPat (p, e) ->
    let body = emit_expr 0 e in
    let oneline = Printf.sprintf "let %s = %s" (emit_pat p) body in
    if fits 0 oneline then oneline
    else Printf.sprintf "let %s =\n  %s" (emit_pat p) (emit_expr 2 e)
  | TLLet (name, [], e) ->
    let body = emit_expr 0 e in
    let oneline = Printf.sprintf "let %s = %s" name body in
    if fits 0 oneline then oneline
    else Printf.sprintf "let %s =\n  %s" name (emit_expr 2 e)
  | TLLet (name, params, e) ->
    (match try_multi_equation params e with
     | Some clauses ->
       String.concat "\n" (List.map (fun (pats, body) ->
         emit_one_equation ("let " ^ name) pats body) clauses)
     | None ->
       let head = "let " ^ name ^ " " ^ String.concat " " (List.map emit_pat params) in
       let oneline = head ^ " = " ^ emit_expr 0 e in
       if fits 0 oneline then oneline
       else head ^ " =\n  " ^ emit_expr 2 e)
  | TLLetRec bindings ->
    let emit_binding kw (name, params, body) =
      let head = kw ^ " " ^ name
        ^ (if params = [] then "" else " " ^ String.concat " " (List.map emit_pat params)) in
      let oneline = head ^ " = " ^ emit_expr 0 body in
      if fits 0 oneline then oneline
      else head ^ " =\n  " ^ emit_expr 2 body
    in
    (match bindings with
     | [] -> ""
     | first :: rest ->
       String.concat "\n" (emit_binding "let" first :: List.map (emit_binding "and") rest))
  | TLExpr e ->
    let s = emit_expr 0 e in
    if fits 0 s then s else emit_expr 0 e

(* ── Comment collection + attachment, and whole-file assembly ───────────────

   Every top-item and every standalone comment is placed into one flat,
   source-ordered list of "pieces". Each piece knows its own start/end
   source line; pieces are then joined with plain newlines (blank lines
   collapsed to at most one), except a comment on the same source line as
   the previous piece's last line, which is appended directly after it
   instead of starting a new line ("trailing same-line" comments). *)

type piece = {
  start_line : int;
  end_line   : int;
  text       : string;
  is_comment : bool;
}

let comment_pieces src tokens =
  List.filter_map (fun (tok, (loc : Token.loc)) ->
    match tok with
    | Token.Comment text ->
      let rendered = "(*" ^ text ^ "*)" in
      let nlines = List.length (String.split_on_char '\n' text) in
      ignore src;
      Some { start_line = loc.line; end_line = loc.line + nlines - 1; text = rendered; is_comment = true }
    | Token.DocComment text ->
      let rendered = "(** " ^ text ^ " *)" in
      let nlines = List.length (String.split_on_char '\n' text) in
      Some { start_line = loc.line; end_line = loc.line + nlines - 1; text = rendered; is_comment = true }
    | _ -> None
  ) tokens

let item_pieces src (prog : program) (item_locs : (Token.loc * Token.loc) list) =
  let items = Array.of_list prog.items in
  let locs  = Array.of_list item_locs in
  let n = Array.length items in
  let next_start_offset i =
    if i + 1 < n then Some (fst locs.(i + 1)).Token.offset else None
  in
  List.init n (fun i ->
    let item = items.(i) in
    let (start_loc, end_loc) : Token.loc * Token.loc = locs.(i) in
    let text =
      if top_item_has_followup item then
        let stop = match next_start_offset i with
          | Some off -> off
          | None -> String.length src
        in
        let raw = String.sub src start_loc.offset (stop - start_loc.offset) in
        (* trim trailing whitespace/newlines only -- leading indentation and
           interior formatting are preserved exactly (verbatim fallback). *)
        let len = String.length raw in
        let j = ref len in
        while !j > 0 && (raw.[!j - 1] = ' ' || raw.[!j - 1] = '\t'
                         || raw.[!j - 1] = '\n' || raw.[!j - 1] = '\r') do decr j done;
        String.sub raw 0 !j
      else
        emit_top_item_pretty item
    in
    { start_line = start_loc.line; end_line = end_loc.line; text; is_comment = false }
  )

let assemble pieces =
  let sorted = List.sort (fun a b -> compare a.start_line b.start_line) pieces in
  let buf = Buffer.create 1024 in
  let prev_end = ref None in
  List.iter (fun p ->
    (match !prev_end with
     | None -> ()
     | Some pel ->
       if p.is_comment && p.start_line = pel then
         Buffer.add_string buf "  "
       else begin
         Buffer.add_char buf '\n';
         if p.start_line - pel - 1 > 0 then Buffer.add_char buf '\n'
       end);
    Buffer.add_string buf p.text;
    prev_end := Some p.end_line
  ) sorted;
  if Buffer.length buf > 0 then Buffer.add_char buf '\n';
  Buffer.contents buf

let format_source src =
  let tokens = Lexer.tokenize src in
  let (prog, item_locs) = Parser.parse_program_with_locs tokens in
  let pieces = comment_pieces src tokens @ item_pieces src prog item_locs in
  assemble pieces
