open Ast

(* ── Small helpers ────────────────────────────────────────────────────────── *)

(* Where a line is expected to end.

   92 rather than 80, which was a terminal's width before it was a habit, and
   rather than the 120 a modern editor would allow. The pane that matters is
   not the one code is written in but the one it is read in: a split diff
   gives each side around ninety columns, and a line past that scrolls
   sideways in the place code is looked at hardest. The same holds for wand
   next to bash in a README or a recording, which is how most of this
   language argues for itself.

   The number shapes the corpus more than it describes it. Measured over
   3,400 lines, the median sits at 41 whatever the margin is, but the 99th
   percentile follows the limit within a column or two -- 87 at a margin of
   88, 97 at 100, 111 at 120. Whatever room is given gets used, by the
   handful of lines that end up in the diff. *)
let max_width = 92

(* Does this fit on the line it is going onto?

   `col` is the column the text will start at, which is not the indentation
   it wraps to: a match case's body is written after `| Some x -> `, so it
   begins some 30 columns right of the case's indent. Measuring from the
   indent said everything fitted and left lines half again over the margin.
   The two coincide only when an expression begins a line, which is why one
   parameter passed for both for so long. *)
(* One case is knowingly left: a closing `)` appended after a body that was
   measured without it, which is this mistake from the other side -- the
   caller knows about the suffix, the callee does not. Three lines in the
   corpus run one to three columns past the margin because of it. The fix is
   a `reserve` threaded alongside `col`, and it is a second concept through
   every emitter for three columns, so it waits until the count grows. *)
let fits col s =
  not (String.contains s '\n') && col + String.length s <= max_width

(* The keyword a binding opens with, and the column its name starts at. A
   binding's later clauses line up under the first one's name rather than at
   a fixed step, so a sibling keyword -- `letrec` -- would carry its own
   clauses across without a second number to keep in step. *)
let let_keyword = "let"

let name_column indent keyword = indent + String.length keyword + 1

let rec strip_located e = match e with
  | Located (_, e) -> strip_located e
  | e -> e

(* The lexer drops a newline written straight after the opening backtick, so
   whether one was there is not in the text. A literal spanning lines gets
   one put back, which is how anyone would have written it and what keeps
   the closing backtick under the opening one; a single-line literal stays
   on its line.

   Idempotent either way, because the newline this adds is exactly the one
   the lexer takes off: a text of "a\nb" emits as backtick, newline, a, b,
   and reads back as "a\nb". A literal that really begins with a blank line
   keeps it for the same reason. *)
let reopen_raw s =
  if String.contains s '\n' then "\n" ^ s else s

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
    (* `${` and `%{` are the two openers the lexer reacts to: `%{` starts an
       interpolation, and `${` is refused as the old spelling. Text holding
       either has to come back escaped or it will not read as itself. *)
    | '$' when i + 1 < n && str.[i + 1] = '{' -> Buffer.add_string buf "\\$"
    | '%' when i + 1 < n && str.[i + 1] = '{' -> Buffer.add_string buf "\\%"
    | c -> Buffer.add_char buf c
  ) str;
  Buffer.contents buf

(* `%g` drops a trailing `.0` for integral floats (`42.0` -> `"42"`), which
   then re-lexes as an Int literal, not a Float -- silently changing the
   program. Force the printed form to always look like a float. *)
let string_of_wand_float f =
  let s = Printf.sprintf "%g" f in
  if String.contains s '.' || String.contains s 'e' || String.contains s 'E'
     || s = "nan" || s = "inf" || s = "-inf"
  then s
  else s ^ ".0"

(* ── Verbatim fallback ─────────────────────────────────────────────────────
   An item whose interior holds a comment is re-emitted as an exact source
   slice. Formatting it would mean deciding where the comment now belongs,
   and a comment moved to the wrong expression is worse than one left where
   its author put it.

   Nothing else falls back: contracts, `handle`, `$()`/`$?()`, `try` and
   regex literals each have a formatting rule. *)

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

(* A map key is written bare when it is an identifier and quoted when it is
   not. `Map` keys are arbitrary strings -- `"content-type"`, `"@type"` -- and
   the parser takes them quoted; printing one of those bare produces source
   that does not lex at all. Quoting is always correct, so the bare form is
   only an economy for the keys that can afford it. *)
let map_key k =
  let plain =
    String.length k > 0
    && (match k.[0] with 'a' .. 'z' | '_' -> true | _ -> false)
    && String.for_all (function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true | _ -> false) k
  in
  if plain then k else "\"" ^ escape_string_body k ^ "\""

let rec emit_pat (p : pat) : string = match p with
  | Int n      -> string_of_int n
  | Float f    -> string_of_wand_float f
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
    "[" ^ String.concat ", " (List.map (fun (k, p) -> map_key k ^ " = " ^ emit_pat p) kvs) ^ "]"

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
   and whose body is a `Match` over those synthetic vars with one case per
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
    | Match (scrutinee, cases) when List.length cases > 1 ->
      let scrutinee_ok = match n, scrutinee with
        | 1, Var v -> v = "_p0"
        | _, Tuple vs ->
          List.length vs = n &&
          List.for_all2 (fun v name -> match strip_located v with
            | Var v -> v = name | _ -> false) vs synthetic_names
        | _ -> false
      in
      if not scrutinee_ok then None
      else if not (List.for_all (fun (_, g, _) -> g = None) cases) then None
      else
        let clauses = List.map (fun (p, _, b) ->
          match n, p with
          | 1, p -> Some ([p], b)
          | _, PTuple ps when List.length ps = n -> Some (ps, b)
          | _ -> None
        ) cases in
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
  | Let _ | LetRec _ | If _ | Match _ | Fn _ | Handle _ | Try _ | Contract _
  | With _ -> true
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

(* `?col` says where the text begins when that is not the indent -- the
   caller knows, because the caller wrote the prefix. Everything defaults to
   the indent, so an emitter that starts its own line needs to say nothing. *)
(* A binding's value may run onto the next line, but not as a bare
   application: `let x =\n  f\n    1\n    2` ends the definition at `f` --
   loudly at the top level, and silently inside a `let ... in`, where the
   lines after it quietly become something else. Every other wrapped form
   carries its own continuation, an operator or a bracket that says the
   expression is not finished. So an application that wrapped gets
   parentheses, and nothing else needs them. *)
(* Only for a top-level item, which is the one place a newline ends a
   definition: the parser breaks an expression at a line end only while no
   bracket is open, so the same shape nested inside a call is fine as it
   stands. *)
let bracket_if_wrapped_app body emitted =
  (* The parser continues a definition onto the next line only while a
     bracket is still open -- `test "x" (fn t ->` ends inside one, so what
     follows belongs to it. A line that closes everything it opened ends the
     definition, and the lines after it become something else. That is the
     condition, so that is what is checked: unclosed brackets at the end of
     the first line. *)
    let depth_after_first_line str =
      let n = String.length str in
      let rec go i depth in_string =
        if i >= n then depth
        else
          match str.[i] with
          | '\n' when not in_string -> depth
          | '\\' when in_string -> go (i + 2) depth in_string
          | '"' -> go (i + 1) depth (not in_string)
          | ('(' | '[') when not in_string -> go (i + 1) (depth + 1) in_string
          | (')' | ']') when not in_string -> go (i + 1) (depth - 1) in_string
          | _ -> go (i + 1) depth in_string
      in
      go 0 0 false
    in
    (* Both conditions, and only together. A `match` or an `if` is safe with
       nothing left open, because its parse is not finished at the first line
       -- the cases are still owed. An application's is: it ends where the
       line does, and what follows is read as something new. *)
    match strip_located body with
    | App _ when String.contains emitted '\n' && depth_after_first_line emitted <= 0 ->
      "(" ^ emitted ^ ")"
    | _ -> emitted

let rec emit_expr ?col indent e =
  emit_expr_inner ?col indent (strip_located e)

(* App-chain function/argument positions require strict "atom" syntax --
   a bare BinOp/UnOp/If/Match/Fn/Let there would be reparsed differently
   (or rejected outright), so always parenthesize those; everything else
   (literals, Var, Field, another App, Tuple/List/MapLit, ...) is already
   safe unwrapped in that position. *)
and emit_atom indent e =
  let e' = strip_located e in
  let s = emit_expr_inner indent e' in
  if is_control_expr e' || is_binop_or_unop e' || is_app e' then "(" ^ s ^ ")" else s

(* An argument, which is an atom with one extra hazard: a bare constructor is
   greedy. `f None x` parses as `f (None x)`, because a constructor takes the
   next atom as its payload -- so `None` is safe only as the final argument,
   where there is nothing left for it to swallow. Dropping those parentheses
   anywhere else changes what the program means, and a formatter that changes
   meaning is worse than no formatter. *)
and emit_arg ~last indent e =
  match strip_located e with
  | Constr _ as c when not last -> "(" ^ emit_expr_inner indent c ^ ")"
  | _ -> emit_atom indent e

and emit_expr_inner ?col indent e =
  let col = match col with Some c -> c | None -> indent in
  match e with
  | Int n      -> string_of_int n
  | Float f    -> string_of_wand_float f
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
  | App _      -> emit_app ~col indent e
  | Fn (ps, body) ->
    (* The body is written after `fn params -> `, so that is where it
       starts -- an `if` in here was the other half of this bug. *)
    let head = "fn " ^ String.concat " " (List.map emit_pat_atom ps) ^ " -> " in
    head ^ emit_expr ~col:(col + String.length head) indent body
  | Let (p, e1, e2) -> emit_let ~col indent p e1 e2
  | LetRec (bindings, e2) -> emit_letrec indent bindings e2
  | If (c, t, el) -> emit_if ~col indent c t el
  | Match (scr, cases) -> emit_match indent scr cases
  | BinOp (op, a, b) -> emit_binop ~col indent op a b
  | UnOp (op, e) -> op ^ emit_atom indent e
  | Tuple es -> emit_sequence ~col indent "(" ")" (List.map (emit_expr indent) es)
  | List es  -> emit_sequence ~col indent "[" "]" (List.map (emit_expr indent) es)
  | ConstrApp (name, kvs) ->
    let field (k, v) =
      (match k with Some n -> n ^ " = " | None -> "") ^ emit_expr indent v in
    let oneline = name ^ "(" ^ String.concat ", " (List.map field kvs) ^ ")" in
    if fits col oneline then oneline
    else
      (* Too wide for a line: one field per line, as a record reads. *)
      let ind = String.make indent ' ' in
      let inner = String.make (indent + 2) ' ' in
      name ^ "(\n" ^ inner
      ^ String.concat (",\n" ^ inner)
          (List.map (fun (k, v) ->
             let label = match k with Some n -> n ^ " = " | None -> "" in
             (* The value is written after its field name, so that is where
                it starts. *)
             label ^ emit_expr ~col:(indent + 2 + String.length label) (indent + 2) v) kvs)
      ^ "\n" ^ ind ^ ")"
  | Field (e, l) -> emit_field indent e l
  | Seq _ as e ->
    (* `;` only sequences inside parentheses, so a Seq is written back in
       that shape: one line when it fits, one statement per line when not. *)
    let rec parts e = match strip_located e with
      | Seq (a, b) -> parts a @ parts b
      | _ -> [e]
    in
    let es = parts e in
    let oneline =
      "(" ^ String.concat "; " (List.map (emit_expr indent) es) ^ ")" in
    if fits col oneline then oneline
    else
      let ind = String.make indent ' ' in
      let inner = String.make (indent + 2) ' ' in
      "(\n" ^ inner
      ^ String.concat (";\n" ^ inner) (List.map (emit_expr (indent + 2)) es)
      ^ "\n" ^ ind ^ ")"
  | Located (_, e) -> emit_expr_inner indent e
  | Contract (reqs, ens, body) ->
    (* Each clause sits on its own line at the body's indent; the first is
       already placed by whatever emitted the binding. *)
    let ind = String.make indent ' ' in
    let clause kw e = kw ^ " " ^ emit_expr indent e in
    String.concat ("\n" ^ ind)
      (List.map (clause "requires") reqs @ List.map (clause "ensures") ens)
    ^ (if reqs = [] && ens = [] then "" else "\n" ^ ind)
    ^ emit_expr indent body
  (* The text inside $() is a command, not a string literal: quoting it
     would hand the whole thing to the shell as one word. *)
  | RunCmd (e, _)   -> "$(" ^ emit_command indent e ^ ")"
  | RunQuery (e, _) -> "$?(" ^ emit_command indent e ^ ")"
  | RegexLit (p, f) -> "r/" ^ p ^ "/" ^ f
  | ImportExpr (StdlibModule n) -> "import " ^ n
  | ImportExpr (UserPath p)     -> "import " ^ p
  (* Given back as it was written. Its content is verbatim by definition, so
     nothing is escaped -- and the newline the lexer dropped after the
     opening backtick is put back, or a reformat would eat one line of
     layout on every pass. *)
  | RawString s -> "`" ^ reopen_raw s ^ "`"
  | RawInterp (parts, tail) ->
    let buf = Buffer.create 32 in
    Buffer.add_char buf '`';
    List.iteri (fun i (lit, e) ->
      Buffer.add_string buf (if i = 0 then reopen_raw lit else lit);
      Buffer.add_string buf "%{";
      Buffer.add_string buf (emit_expr indent e);
      Buffer.add_char buf '}'
    ) parts;
    Buffer.add_string buf tail;
    Buffer.add_char buf '`';
    Buffer.contents buf
  | Interp (parts, tail) ->
    let buf = Buffer.create 32 in
    Buffer.add_char buf '"';
    List.iter (fun (lit, e) ->
      Buffer.add_string buf (escape_string_body lit);
      (* `$NAME` is plain text in a string now, so an env read has to be
         written out as the expression it is: `%{$HOME}`. *)
      Buffer.add_string buf "%{";
      Buffer.add_string buf (emit_expr indent e);
      Buffer.add_char buf '}'
    ) parts;
    Buffer.add_string buf (escape_string_body tail);
    Buffer.add_char buf '"';
    Buffer.contents buf
  (* Only reachable inside `$()`, which `emit_cmd` handles; rendered here so
     the match is total and so a stray one is still legible. *)
  | CmdInterp (parts, tail) ->
    let buf = Buffer.create 32 in
    List.iter (fun (lit, e, raw) ->
      Buffer.add_string buf lit;
      Buffer.add_string buf (if raw then "%!{" else "%{");
      Buffer.add_string buf (emit_expr indent e);
      Buffer.add_char buf '}'
    ) parts;
    Buffer.add_string buf tail;
    Buffer.contents buf
  | Handle (body, cases) ->
    let emit_arm = function
      | EffectCase (op, p, k, b) ->
        Printf.sprintf "| %s %s %s -> %s" op (emit_pat p) k (emit_case_body indent b)
      | ReturnCase (p, b) ->
        Printf.sprintf "| return %s -> %s" (emit_pat p) (emit_case_body indent b)
    in
    "handle " ^ emit_expr indent body ^ " with\n"
    ^ String.make indent ' ' ^ String.concat ("\n" ^ String.make indent ' ')
        (List.map emit_arm cases)
  | Try e -> "try " ^ emit_expr indent e
  (* The body stays at the bracket's own indentation rather than stepping in.
     Brackets nest -- a temp dir holding a lock holding a directory change --
     and indenting each one would push the actual work off the page for
     something that reads as a preamble, not as nesting. *)
  | With (r, p, body) ->
    let head = Printf.sprintf "with %s as %s ->" (emit_expr indent r) (emit_pat p) in
    let one_line = head ^ " " ^ emit_expr indent body in
    if fits col one_line then one_line
    else head ^ "\n" ^ String.make indent ' ' ^ emit_expr indent body
  | Annot (te, e) -> emit_atom indent e ^ " : " ^ emit_type_expr te
  | MapLit kvs ->
    emit_sequence indent "[" "]"
      (List.map (fun (k, e) -> map_key k ^ " = " ^ emit_expr (indent + 2) e) kvs)

and emit_app ?col indent e =
  let col = match col with Some c -> c | None -> indent in
  let rec flatten e = match strip_located e with
    | App (f, x) -> let (h, args) = flatten f in (h, args @ [x])
    | other -> (other, [])
  in
  let (head, args) = flatten e in
  if args = [] then emit_expr indent head
  else
    let emit_args ind =
      let n = List.length args in
      List.mapi (fun i a -> emit_arg ~last:(i = n - 1) ind a) args
    in
    let oneline = emit_atom indent head ^ " " ^ String.concat " " (emit_args indent) in
    if fits col oneline then oneline
    else
      (* Too wide. A trailing lambda is the common shape -- `test "..." (fn t
         -> ...)` -- and reads best with its body on the next line, the way
         it would have been written by hand. *)
      let ind = String.make indent ' ' in
      let inner = String.make (indent + 2) ' ' in
      let rec split_last acc = function
        | [x]     -> (List.rev acc, Some x)
        | x :: tl -> split_last (x :: acc) tl
        | []      -> (List.rev acc, None)
      in
      (match split_last [] args with
       | before, Some last ->
         (match strip_located last with
          | Fn (ps, body) ->
            let prefix =
              String.concat " "
                (emit_atom indent head
                 :: List.map (fun a -> emit_arg ~last:false indent a) before)
            in
            prefix ^ " (fn " ^ String.concat " " (List.map emit_pat_atom ps)
            ^ " ->\n" ^ inner ^ emit_expr (indent + 2) body ^ ")"
          | _ ->
            (* Otherwise one argument per line, under the head. *)
            emit_atom indent head ^ "\n" ^ inner
            ^ String.concat ("\n" ^ inner) (emit_args (indent + 2))
            ^ (if ind = "" then "" else ""))
       | _, None -> oneline)

(* A command's text, with interpolations left as %{...} and nothing quoted. *)
and emit_command indent e =
  match strip_located e with
  | String s -> s
  | Interp (parts, tail) ->
    let buf = Buffer.create 32 in
    List.iter (fun (lit, ex) ->
      Buffer.add_string buf lit;
      Buffer.add_string buf "%{";
      Buffer.add_string buf (emit_expr indent ex);
      Buffer.add_char buf '}') parts;
    Buffer.add_string buf tail;
    Buffer.contents buf
  (* Which form each interpolation used has to survive formatting: rewriting
     `%!{x}` as `%{x}` would quietly quote a splice that was meant to be
     shell source, and the script would stop working. *)
  | CmdInterp (parts, tail) ->
    let buf = Buffer.create 32 in
    List.iter (fun (lit, ex, raw) ->
      Buffer.add_string buf lit;
      Buffer.add_string buf (if raw then "%!{" else "%{");
      Buffer.add_string buf (emit_expr indent ex);
      Buffer.add_char buf '}') parts;
    Buffer.add_string buf tail;
    Buffer.contents buf
  | other -> emit_expr indent other

and emit_field indent e l =
  let e' = strip_located e in
  let target = match e' with
    | BinOp _ | UnOp _ | Let _ | LetRec _ | If _ | Match _ | Fn _
    | Handle _ | Try _ | Contract _ -> "(" ^ emit_expr indent e' ^ ")"
    | _ -> emit_expr indent e'
  in
  target ^ "." ^ l

(* Items on one line while they fit, one per line when they do not. The
   brackets carry the break rather than the items being aligned under the
   opening one: alignment moves every line when the head changes, which
   makes a diff of a formatted file larger than the edit that caused it. *)
and emit_sequence ?col indent opening closing items =
  let col = match col with Some c -> c | None -> indent in
  let oneline = opening ^ String.concat ", " items ^ closing in
  if fits col oneline then oneline
  else
    let inner = String.make (indent + 2) ' ' in
    opening ^ "\n" ^ inner
    ^ String.concat (",\n" ^ inner) items
    ^ "\n" ^ String.make indent ' ' ^ closing

(* A pipeline reads as a list of stages, so when it does not fit it breaks
   into one stage per line with the operator leading -- which is where a
   reader looks to see what happens next, and what makes the stages line up
   under each other. *)
and emit_pipeline indent a b =
  let rec stages e =
    match strip_located e with
    | BinOp ("|>", l, r) -> stages l @ [r]
    | other -> [other]
  in
  let all = stages (BinOp ("|>", a, b)) in
  let piece e =
    match strip_located e with
    | (Try _ | Handle _ | Contract _ | Fn _ | If _ | Match _
      | Let _ | LetRec _ | With _) as inner -> "(" ^ emit_expr indent inner ^ ")"
    | _ -> emit_expr (indent + 2) e
  in
  match List.map piece all with
  | [] -> ""
  | first :: rest ->
    let inner = String.make (indent + 2) ' ' in
    first ^ String.concat "" (List.map (fun s -> "\n" ^ inner ^ "|> " ^ s) rest)

and emit_binop ?col indent op a b =
  let col = match col with Some c -> c | None -> indent in
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
    (* These extend as far to the right as they can, so an operand needs
       parentheses or the operator is swallowed into it: `(try e) == x`
       printed bare re-parses as `try (e == x)`. *)
    | (Try _ | Handle _ | Contract _ | Fn _ | If _ | Match _
      | Let _ | LetRec _) as inner -> "(" ^ emit_expr indent inner ^ ")"
    | _ -> emit_expr indent e
  in
  let oneline = Printf.sprintf "%s %s %s" (side_str `Left a) op (side_str `Right b) in
  if op = "|>" && not (fits col oneline) then emit_pipeline indent a b
  else oneline

(* If `body` is `Annot (te, real_body)` -- a return-type annotation on a
   function clause (`let f x : T = body`) -- return the ": T" to append to
   the clause head and the real body to print after `=`. Printed after `=`
   instead, `: T` is ambiguous with the cons operator (same hazard as
   emit_let's own Annot case below), so it must move before it. *)
and split_clause_annot body =
  match strip_located body with
  | Annot (te, real_body) -> (" : " ^ emit_type_expr te, real_body)
  | _ -> ("", body)

and emit_let ?col indent p e1 e2 =
  let col = match col with Some c -> c | None -> indent in
  match e1 with
  | Fn (params, fbody) ->
    (* A *raw* (non-`Located`) `Fn` as a `let` RHS only ever comes from the
       shorthand `let name params = body` parse (parser.ml:705) -- the one
       form the typechecker treats as recursive (typechecker.ml:658-659,
       matches literal `Fn _`, not `Located (_, Fn _)`). Reprinting it as
       `let name = fn params -> body` would silently make it non-recursive,
       so it must always come back out as shorthand syntax, single-clause or
       multi-equation alike. *)
    let name = match p with PVar n -> n | _ -> "_" in
    let ind = String.make indent ' ' in
    let clauses = match try_multi_equation params fbody with
      | Some cs -> cs
      | None    -> [(params, fbody)]
    in
    (* The first clause carries the keyword and fixes the column its name
       starts at; the rest are that name again, under it. The `in` closes
       the group from the keyword's own column, so the block reads as one
       shape rather than a stack of unrelated lines. *)
    let clause_indent i = if i = 0 then indent else name_column indent let_keyword in
    let lines = List.mapi (fun i (pats, body) ->
      let ci = clause_indent i in
      let cind = String.make ci ' ' in
      let kw = if i = 0 then let_keyword ^ " " ^ name else name in
      let (annot_s, body) = split_clause_annot body in
      let head = kw ^ " " ^ String.concat " " (List.map emit_pat_atom pats) ^ annot_s in
      (* Measured from where this clause actually starts, not from the
         group's column, or a later clause is allowed a line it cannot fit. *)
      let clause_col = if i = 0 then col else ci in
      let oneline = head ^ " = " ^ emit_expr ci body in
      if fits clause_col oneline then oneline
      else begin match strip_located body with
        (* A sequence body opens its parenthesis on the `=` line, so the
           block reads brace-style; the Seq emitter, told its true starting
           column, cannot fit and takes its multiline form. *)
        | Seq _ ->
          head ^ " = "
          ^ emit_expr ~col:(clause_col + String.length head + 3) ci body
        | _ -> head ^ " =\n" ^ cind ^ "  " ^ emit_expr (ci + 2) body
      end
    ) clauses in
    let joined =
      String.concat "\n"
        (List.mapi (fun i l ->
           if i = 0 then l else String.make (clause_indent i) ' ' ^ l) lines)
    in
    joined ^ "\n" ^ ind ^ "in " ^ emit_expr indent e2
  | Annot (te, body) ->
    (* Reprinting an `Annot`'d let RHS via inline `expr : Type` syntax would
       be genuinely ambiguous: the parser's infix `:` in expression position
       always means cons (list prepend), never ascription, so
       `let x = e : T in ...` re-parses as "cons e onto T", not "e annotated
       with type T". Must go back out through the dedicated
       `let name : T = e` syntax (parser.ml:707-717) instead. *)
    let name = emit_pat p in
    let bodys = emit_expr indent body and e2s = emit_expr indent e2 in
    let head = "let " ^ name ^ " : " ^ emit_type_expr te in
    let oneline = head ^ " = " ^ bodys ^ " in " ^ e2s in
    if fits col oneline then oneline
    else
      let ind = String.make indent ' ' in
      Printf.sprintf "%s = %s in\n%s%s" head bodys ind e2s
  | _ ->
  let e1s = emit_expr indent e1 and e2s = emit_expr indent e2 in
  let oneline = Printf.sprintf "let %s = %s in %s" (emit_pat p) e1s e2s in
  let ind = String.make indent ' ' in
  if fits col oneline then oneline
  else
    (* Splitting after `in` is the first thing to try, but the binding alone
       may still be too long -- and the value was rendered as though it began
       at the margin, not after `let name = `. Given its own line it gets the
       room the measurement assumed, and wraps on its own terms. *)
    let bound = Printf.sprintf "let %s = %s in" (emit_pat p) e1s in
    if fits col bound then
      (match strip_located e2 with
       (* A sequence after `in` opens its parenthesis on the same line,
          brace-style, like a sequence after `=`. *)
       | Seq _ ->
         bound ^ " " ^ emit_expr ~col:(col + String.length bound + 1) indent e2
       | _ -> bound ^ "\n" ^ ind ^ e2s)
    else
      Printf.sprintf "let %s =\n%s  %s\n%sin\n%s%s"
        (emit_pat p) ind (emit_expr (indent + 2) e1) ind ind e2s

and emit_letrec indent bindings e2 =
  let emit_binding kw (name, params, body) =
    let (annot_s, body) = split_clause_annot body in
    kw ^ " " ^ name
    ^ (if params = [] then "" else " " ^ String.concat " " (List.map emit_pat_atom params))
    ^ annot_s ^ " = " ^ emit_expr indent body
  in
  let ind = String.make indent ' ' in
  let lines = match bindings with
    | [] -> []
    | first :: rest ->
      emit_binding "let" first :: List.map (emit_binding "and") rest
  in
  String.concat ("\n" ^ ind) lines ^ "\n" ^ ind ^ "in " ^ emit_expr indent e2

and emit_if ?col indent c t el =
  let col = match col with Some c -> c | None -> indent in
  let cs = emit_expr indent c and ts = emit_expr indent t in
  (* A branch that does nothing is written by leaving it out, so `else ()` --
     however it was written -- comes back as the one-armed form. *)
  match strip_located el with
  | Unit ->
    let oneline = Printf.sprintf "if %s then %s" cs ts in
    if fits col oneline then oneline
    else Printf.sprintf "if %s then\n%s%s" cs (String.make (indent + 2) ' ') ts
  | _ ->
    let es = emit_expr indent el in
    let oneline = Printf.sprintf "if %s then %s else %s" cs ts es in
    if fits col oneline then oneline
    else
      let ind = String.make indent ' ' in
      Printf.sprintf "if %s then %s\n%selse %s" cs ts ind es

(* A `match`/`handle` case body ends only where the next `|`-prefixed case
   begins -- there's no other terminator. So an unparenthesized Match or
   Handle used as an case's *own* body would greedily swallow every
   following `| ...` meant for the *outer* match/handle, silently
   producing a different (and often ill-typed) program. Always wrap.

   The danger isn't limited to the case body being *directly* a Match/Handle:
   `let x = e in <tail>` prints its tail expression completely unguarded
   (see emit_let's fallback), so `let db = ... in match ... with | ... `
   as an case body has the exact same "bare match at the end" shape once
   rendered, even though the immediate AST node is a Let. Follow the chain
   of Let/LetRec tails to find what actually ends up printed last. *)
and case_body_tail e = match strip_located e with
  | Let (_, _, e2)    -> case_body_tail e2
  | LetRec (_, e2)     -> case_body_tail e2
  | e -> e

and emit_case_body ?col indent body =
  match case_body_tail body with
  | Match _ | Handle _ -> "(" ^ emit_expr ?col indent body ^ ")"
  | _ -> emit_expr ?col indent body

(* The scrutinee shares its own "with" keyword with any enclosing match's
   "with", so an unparenthesized nested Match there is fragile even when
   it happens to parse back correctly -- always wrap for clarity/safety. *)
and emit_scrutinee indent scr =
  match strip_located scr with
  | Match _ -> "(" ^ emit_expr indent scr ^ ")"
  | _ -> emit_expr indent scr

and emit_match indent scr cases =
  let ind = String.make indent ' ' in
  let emit_case (p, guard, body) =
    let guard_s = match guard with
      | None -> ""
      | Some g -> " when " ^ emit_expr indent g
    in
    (* The body starts after the pattern and the arrow, not at the case's
       indent -- which is the whole of this bug. *)
    let prefix = ind ^ "| " ^ emit_pat p ^ guard_s ^ " -> " in
    prefix ^ emit_case_body ~col:(String.length prefix) indent body
  in
  "match " ^ emit_scrutinee indent scr ^ " with\n"
  ^ String.concat "\n" (List.map emit_case cases)

let emit_one_equation head_kw pats body =
  let (annot_s, body) = split_clause_annot body in
  let head = head_kw ^ " " ^ String.concat " " (List.map emit_pat_atom pats) ^ annot_s in
  let oneline = head ^ " = " ^ emit_expr 0 body in
  if fits 0 oneline then oneline
  else head ^ " =\n  " ^ bracket_if_wrapped_app body (emit_expr 2 body)

(* ── Type definitions ─────────────────────────────────────────────────────── *)

(* A named field's type may be an application -- `children: List Node` -- and
   is written without parentheses, since the comma or the closing paren ends
   it. A positional field may not: `Pair Int Int` is two fields, not one
   applied to the other, so those stay atoms. An arrow needs its parentheses
   either way, and `emit_type_app_expr` still adds them. *)
let emit_named_field_type t = emit_type_app_expr t

let emit_ctor_fields fields =
  if fields = [] then ""
  else match fields with
    | (Some _, _) :: _ ->
      "(" ^ String.concat ", " (List.map (fun (n, t) ->
        Option.get n ^ ": " ^ emit_named_field_type t) fields) ^ ")"
    | _ ->
      " " ^ String.concat " " (List.map (fun (_, t) -> emit_type_atom t) fields)

(* Named fields, one per line, for a constructor too wide to fit. Positional
   fields are left alone: they are type atoms, so a long positional
   constructor is long because its types are, and breaking it up does not
   help. *)
let emit_ctor_fields_wrapped name fields =
  match fields with
  | (Some _, _) :: _ ->
    name ^ "(\n"
    ^ String.concat ",\n"
        (List.map (fun (n, t) ->
           "  " ^ Option.get n ^ ": " ^ emit_named_field_type t) fields)
    ^ "\n)"
  | _ -> name ^ emit_ctor_fields fields

let emit_type_def (Variants (name, params, ctors)) =
  let head =
    "type " ^ name
    ^ (if params = [] then "" else " " ^ String.concat " " (List.map (fun p -> "'" ^ p) params))
    ^ " = "
  in
  let oneline =
    head ^ String.concat " | " (List.map (fun c -> c.name ^ emit_ctor_fields c.fields) ctors)
  in
  if fits 0 oneline then oneline
  else match ctors with
    (* A single constructor with named fields is a record: widen it down the
       page rather than past the margin. Several constructors wrap at the
       alternatives instead, which is where a reader looks first. *)
    | [c] -> head ^ emit_ctor_fields_wrapped c.name c.fields
    | _ ->
      head ^ "\n  "
      ^ String.concat "\n  | "
          (List.map (fun c -> c.name ^ emit_ctor_fields c.fields) ctors)

(* ── Top-level items ──────────────────────────────────────────────────────── *)

let emit_top_item_pretty = function
  | TLImport (StdlibModule n) -> "import " ^ n
  | TLImport (UserPath p)     -> "import " ^ p
  | TLType tdef -> emit_type_def tdef
  | TLLetPat (p, e) ->
    let body = emit_expr 0 e in
    let oneline = Printf.sprintf "let %s = %s" (emit_pat p) body in
    if fits 0 oneline then oneline
    else
      Printf.sprintf "let %s =\n  %s" (emit_pat p)
        (bracket_if_wrapped_app e (emit_expr 2 e))
  | TLLet (name, [], Annot (te, body)) ->
    (* Same ambiguity as the local-`let` case: reprinting via inline
       `expr : Type` would re-parse as cons, not ascription -- keep the
       dedicated `let name : T = e` syntax. *)
    let bodys = emit_expr 0 body in
    let head = "let " ^ name ^ " : " ^ emit_type_expr te in
    let oneline = head ^ " = " ^ bodys in
    if fits 0 oneline then oneline
    else head ^ " =\n  " ^ bracket_if_wrapped_app body (emit_expr 2 body)
  | TLLet (name, [], e) ->
    let body = emit_expr 0 e in
    let oneline = Printf.sprintf "let %s = %s" name body in
    if fits 0 oneline then oneline
    else Printf.sprintf "let %s =\n  %s" name (bracket_if_wrapped_app e (emit_expr 2 e))
  | TLLet (name, params, e) ->
    (match try_multi_equation params e with
     | Some clauses ->
       String.concat "\n" (List.map (fun (pats, body) ->
         emit_one_equation ("let " ^ name) pats body) clauses)
     | None ->
       let (annot_s, e) = split_clause_annot e in
       let head = "let " ^ name ^ " " ^ String.concat " " (List.map emit_pat_atom params) ^ annot_s in
       let oneline = head ^ " = " ^ emit_expr 0 e in
       if fits 0 oneline then oneline
       else begin match strip_located e with
         (* A sequence body opens its parenthesis on the `=` line, so the
            block reads brace-style. *)
         | Seq _ ->
           head ^ " = " ^ emit_expr ~col:(String.length head + 3) 0 e
         | _ -> head ^ " =\n  " ^ emit_expr 2 e
       end)
  | TLLetRec bindings ->
    let emit_binding kw (name, params, body) =
      let (annot_s, body) = split_clause_annot body in
      let head = kw ^ " " ^ name
        ^ (if params = [] then "" else " " ^ String.concat " " (List.map emit_pat_atom params))
        ^ annot_s in
      let oneline = head ^ " = " ^ emit_expr 0 body in
      if fits 0 oneline then oneline
      else head ^ " =\n  " ^ emit_expr 2 body
    in
    (match bindings with
     | [] -> ""
     | first :: rest ->
       String.concat "\n" (emit_binding "let" first :: List.map (emit_binding "and") rest))
  | TLExpr e ->
    (* A top-level expression is subject to the same rule as a binding's
       value: wrapped as a bare application it stops being one expression. *)
    bracket_if_wrapped_app e (emit_expr 0 e)

(* ── Comment collection + attachment, and whole-file assembly ───────────────

   Every top-item and every standalone comment is placed into one flat,
   source-ordered list of "pieces". Each piece knows its own start/end
   source line; pieces are then joined with plain newlines (blank lines
   collapsed to at most one), except a comment on the same source line as
   the previous piece's last line, which is appended directly after it
   instead of starting a new line ("trailing same-line" comments). *)

type piece = {
  offset     : int;   (* source offset: pieces are emitted in source order *)
  start_line : int;
  end_line   : int;
  text       : string;
  is_comment : bool;
}

type comment_tok = { c_offset : int; c_start_line : int; c_end_line : int; c_text : string }

let all_comments tokens : comment_tok list =
  List.filter_map (fun (tok, (loc : Token.loc)) ->
    match tok with
    | Token.Comment text ->
      let rendered = "(*" ^ text ^ "*)" in
      let nlines = List.length (String.split_on_char '\n' text) in
      Some { c_offset = loc.offset; c_start_line = loc.line;
             c_end_line = loc.line + nlines - 1; c_text = rendered }
    | Token.LineComment text ->
      (* Rendered back as `--`: the formatter must not rewrite one comment
         style into the other. A line comment is always exactly one line. *)
      Some { c_offset = loc.offset; c_start_line = loc.line;
             c_end_line = loc.line; c_text = "--" ^ text }
    | Token.DocComment text ->
      (* The lexer strips each line's indentation and star prefix, so that
         `wand d` prints clean prose. Re-indent continuation lines under the
         opening delimiter rather than emitting them flush left. *)
      let rendered =
        "(** "
        ^ String.concat "\n    " (String.split_on_char '\n' text)
        ^ " *)"
      in
      let nlines = List.length (String.split_on_char '\n' text) in
      Some { c_offset = loc.offset; c_start_line = loc.line;
             c_end_line = loc.line + nlines - 1; c_text = rendered }
    | _ -> None
  ) tokens

(* Trim trailing whitespace/newlines only -- leading indentation and
   interior formatting are preserved exactly (verbatim rendering). *)
let rstrip_ws raw =
  let len = String.length raw in
  let j = ref len in
  while !j > 0 && (raw.[!j - 1] = ' ' || raw.[!j - 1] = '\t'
                   || raw.[!j - 1] = '\n' || raw.[!j - 1] = '\r') do decr j done;
  String.sub raw 0 !j

(* For each item, decide its rendered text and its [start_offset, stop)
   span. An item falls back to an exact verbatim source slice whenever it
   contains a follow-up-tier construct (Contract/Handle/RunCmd/RunQuery/
   Try/RegexLit -- no dedicated formatting rule yet) OR contains a comment
   inside its own span (multi-equation clauses, or a comment inside a
   function body): pretty-printing would otherwise have to either drop
   that comment or relocate it outside the item, so the safe fallback is
   to leave the whole item exactly as written. *)
let item_pieces (src : string) (prog : program) (item_locs : (Token.loc * Token.loc) list)
    (comments : comment_tok list) =
  let items = Array.of_list prog.items in
  let locs  = Array.of_list item_locs in
  let n = Array.length items in
  let stop_offset i =
    if i + 1 < n then (fst locs.(i + 1)).Token.offset else String.length src
  in
  List.init n (fun i ->
    let item = items.(i) in
    let (start_loc, end_loc) : Token.loc * Token.loc = locs.(i) in
    let stop = stop_offset i in
    let has_interior_comment =
      List.exists (fun c -> c.c_offset > start_loc.offset && c.c_offset < end_loc.offset) comments
    in
    let is_verbatim = has_interior_comment in
    let text =
      if is_verbatim then rstrip_ws (String.sub src start_loc.offset (stop - start_loc.offset))
      else emit_top_item_pretty item
    in
    (* A verbatim slice runs to the next item's offset, so it absorbs any
       comment sitting between the two. Its text therefore ends later than
       the AST's end_loc says, and trusting that would leave an apparent gap
       for `assemble` to fill with a blank line -- separating a doc comment
       from the binding it documents. Count the lines actually emitted. *)
    let end_line =
      if is_verbatim then
        start_loc.line + List.length (String.split_on_char '\n' text) - 1
      else end_loc.line
    in
    let piece = { offset = start_loc.offset; start_line = start_loc.line;
                  end_line; text; is_comment = false } in
    (is_verbatim, start_loc.offset, stop, piece))

let assemble pieces =
  (* Source order, not line order: an item and a comment can start on the
     same line, and which came first decides whether the comment trails the
     item or introduces it. *)
  let sorted = List.sort (fun a b -> compare a.offset b.offset) pieces in
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
  let comments = all_comments tokens in
  let items = item_pieces src prog item_locs comments in
  let verbatim_spans = List.filter_map (fun (v, s, e, _) -> if v then Some (s, e) else None) items in
  let in_any_span off = List.exists (fun (s, e) -> off > s && off < e) verbatim_spans in
  let comment_pcs = List.filter_map (fun c ->
    if in_any_span c.c_offset then None
    else Some { offset = c.c_offset; start_line = c.c_start_line;
                end_line = c.c_end_line; text = c.c_text; is_comment = true }
  ) comments in
  let item_pcs = List.map (fun (_, _, _, p) -> p) items in
  (* A manifest is not a top-level item -- it is held apart on the program,
     since it is a property of the file rather than something in it -- so it
     has to be emitted here or the formatter would silently drop it, turning
     a bounded file into an unbounded one. *)
  let manifest_pcs =
    match prog.Ast.manifest with
    | None -> []
    | Some (labels, loc) ->
      [{ offset     = loc.Token.offset;
         start_line = loc.Token.line;
         end_line   = loc.Token.line;
         text       = "uses {"
                      ^ String.concat ", " (List.map Shell_scan.render_label labels)
                      ^ "}";
         is_comment = false }]
  in
  assemble (manifest_pcs @ comment_pcs @ item_pcs)
