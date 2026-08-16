open Ast

exception ParseError of string

type state = {
  tokens : (Token.t * Token.loc) array;
  mutable pos : int;
  mutable in_contract : bool;
  mutable paren_depth : int;
    (* depth of unclosed (/[/{ -- lets newline-significance checks tell "end
       of statement" apart from "still inside an open bracket" *)
  top_fns : (string, int) Hashtbl.t;
    (* function name -> arity, for top-level definitions already completed.
       A function's equations are parsed as one contiguous group, so seeing
       a name here again means a later `let` for it after a gap. *)
  mutable with_owners : int;
    (* how many enclosing constructs are waiting to consume a `with` --
       a `match` scrutinee or `handle` body in progress. `try e` followed
       by `with` is OCaml drift worth naming, but only when no such owner
       is waiting: `match try thunk () with | ...` is idiomatic wand. *)
  mutable shell_allow : string list option;
    (* the manifest's Shell(...) allowlist, once one has been parsed --
       stamped onto every $()/$?() site so the bound travels with the
       site's AST wherever its closure goes. *)
}

let make tokens =
  { tokens = Array.of_list tokens; pos = 0; in_contract = false;
    paren_depth = 0; top_fns = Hashtbl.create 16; with_owners = 0;
    shell_allow = None }

(* Plain `Comment _` tokens are invisible to the real parser, exactly like
   `Newline` -- only `DocComment` is left unfiltered (parse_program's
   dispatch relies on seeing it for doc-string attachment). *)
let is_skippable = function
  | Token.Newline | Token.Comment _ | Token.LineComment _ -> true
  | _ -> false

let skip s =
  while s.pos < Array.length s.tokens
     && is_skippable (fst s.tokens.(s.pos)) do
    s.pos <- s.pos + 1
  done

(* A comment counts as a line break if it's a `Newline` token, or if it's a
   (possibly multi-line) `Comment` whose text itself contains a newline --
   there's no separate `Newline` token adjacent to a comment that already
   spans multiple lines. *)
let has_newline_before_next s =
  let i = ref s.pos in
  let seen_break = ref false in
  let continue_ = ref true in
  while !continue_ && !i < Array.length s.tokens do
    (match fst s.tokens.(!i) with
     | Token.Newline -> seen_break := true; incr i
     | Token.Comment text ->
       if String.contains text '\n' then seen_break := true;
       incr i
     (* A line comment never contains its own newline -- the `Newline` token
        that follows it supplies the break. *)
     | Token.LineComment _ -> incr i
     | _ -> continue_ := false)
  done;
  !seen_break

(* A newline only ends a statement/application chain outside of any open
   bracket -- inside one (still-open call args, list/tuple elements, ...) it's
   just formatting, and the enclosing bracket's own `expect ... RParen`-style
   check is what will catch a genuinely malformed program. Without this,
   an unclosed application spanning a newline could silently be read as two
   unrelated statements instead of either parsing correctly or erroring. *)
let newline_breaks_expr s = has_newline_before_next s && s.paren_depth = 0

let peek s =
  let i = ref s.pos in
  while !i < Array.length s.tokens && is_skippable (fst s.tokens.(!i)) do incr i done;
  if !i < Array.length s.tokens then fst s.tokens.(!i) else Token.EOF

let peek_loc s =
  let i = ref s.pos in
  while !i < Array.length s.tokens && is_skippable (fst s.tokens.(!i)) do incr i done;
  if !i < Array.length s.tokens then snd s.tokens.(!i) else Token.{ line = 0; col = 0; offset = 0 }

let advance s =
  skip s;
  if s.pos >= Array.length s.tokens then Token.EOF
  else begin
    let t = fst s.tokens.(s.pos) in
    s.pos <- s.pos + 1;
    (match t with
     | Token.LParen | Token.LBracket | Token.LBrace -> s.paren_depth <- s.paren_depth + 1
     | Token.RParen | Token.RBracket | Token.RBrace -> s.paren_depth <- max 0 (s.paren_depth - 1)
     | _ -> ());
    t
  end

let advance_loc s =
  skip s;
  if s.pos >= Array.length s.tokens
  then (Token.EOF, Token.{ line = 0; col = 0; offset = 0 })
  else begin
    let pair = s.tokens.(s.pos) in
    s.pos <- s.pos + 1; pair
  end

let loc_prefix s =
  let l = peek_loc s in
  Printf.sprintf "%d:%d: " l.Token.line l.Token.col

(* Returns true if the upcoming LParen (not yet consumed) is followed by "ident =" *)
let peek_named_args s =
  let arr = s.tokens in
  let n = Array.length arr in
  let i = ref s.pos in
  let skip () = while !i < n && is_skippable (fst arr.(!i)) do incr i done in
  skip ();
  if !i >= n || fst arr.(!i) <> Token.LParen then false
  else begin
    incr i; skip ();
    if !i >= n then false
    else match fst arr.(!i) with
    | Token.Ident _ ->
      incr i; skip ();
      !i < n && fst arr.(!i) = Token.Eq
    | _ -> false
  end

let keywords = [
  "let"; "in"; "match"; "with"; "if"; "then"; "else"; "fn"; "fun";
  "type"; "start"; "import"; "when"; "of"; "and"; "or";
  "handle"; "return"
]

let keyword_hint = function
  | Token.Ident s -> Util.hint s keywords
  (* Corrections for reserved words a reader of OCaml or Python would
     reach for; naming the wand spelling here is what makes the
     edit-typecheck loop converge instead of circle. *)
  | Token.And ->
    " -- the boolean operator is '&&'; wand's 'and' only joins mutually \
     recursive let bindings"
  | Token.Or -> " -- the boolean operator is '||'"
  | Token.Of ->
    " -- 'of' is OCaml; a wand constructor takes its payload directly: \
     'Circle Int', not 'Circle of Int'"
  | _ -> ""

let expect s tok =
  let loc = loc_prefix s in
  let t = advance s in
  if not (Token.equal t tok) then
    raise (ParseError (Format.asprintf "%sexpected %a, got %a%s"
      loc Token.pp tok Token.pp t (keyword_hint t)))

let expect_ident s =
  let loc = loc_prefix s in
  match advance s with
  | Token.Ident name -> name
  | t -> raise (ParseError (Format.asprintf "%sexpected identifier, got %a" loc Token.pp t))

(* A handler case's continuation binder. `_` is allowed and means the case
   answers without resuming -- a normal thing to write now that abandoning a
   continuation releases what the abandoned code was holding. It binds a
   name no expression can mention, so the intent is stated rather than
   left to a reader noticing that some `k` is never used. *)
let expect_cont_name s =
  let loc = loc_prefix s in
  match advance s with
  | Token.Ident name -> name
  | Token.Underscore -> "_"
  | t -> raise (ParseError (Format.asprintf
      "%sexpected a name for the continuation, or _ if it is not resumed, \
       got %a" loc Token.pp t))

(* ── Binding powers ───────────────────────────────────────────────────────── *)

let lbp = function
  | Token.PipeArrow   -> 10
  | Token.Colon       -> 15
  | Token.PipePipe  -> 20
  | Token.AmpAmp    -> 30
  | Token.EqEq | Token.BangEq
  | Token.Lt   | Token.Gt
  | Token.LtEq | Token.GtEq -> 40
  | Token.Plus | Token.Minus | Token.PlusPlus -> 50
  | Token.Star | Token.Slash | Token.Percent -> 60
  | Token.Dot  -> 80
  | _ -> 0

let is_atom_start = function
  | Token.Int _ | Token.Float _ | Token.String _ | Token.Bool _
  | Token.Path _ | Token.Glob _ | Token.Date _ | Token.Time _ | Token.DateTime _
  | Token.Duration _ | Token.Url _ | Token.IPv4 _ | Token.CIDR _
  | Token.Port _ | Token.Version _ | Token.Size _
  | Token.Ident _ | Token.Upper _ | Token.Hole
  | Token.LParen | Token.LBracket
  | Token.Dollar | Token.InterpStr _ | Token.RunCmdRaw _ | Token.RunQueryRaw _
  | Token.RawStr _ | Token.RawInterpStr _
  | Token.Regex _ | Token.EnvVar _ | Token.Import
  | Token.Handle | Token.Try -> true
  | _ -> false

let is_expr_start = function
  | Token.Let | Token.If | Token.Match | Token.Fn
  | Token.Minus | Token.Bang -> true
  | t -> is_atom_start t

let is_pat_atom_start = function
  | Token.Int _ | Token.Float _ | Token.String _ | Token.RawStr _ | Token.Bool _
  | Token.Ident _ | Token.Underscore | Token.Upper _
  | Token.LParen | Token.LBracket -> true
  | _ -> false

(* ── Pattern parsing ──────────────────────────────────────────────────────── *)

let rec pat_ s =
  match peek s with
  | Token.Int n      -> ignore (advance s); (Int n : pat)
  | Token.Float f    -> ignore (advance s); Float f
  | Token.String str -> ignore (advance s); String str
  (* A backtick string is a string; a pattern has no interpolation to keep
     apart, so it needs no separate form. *)
  | Token.RawStr str -> ignore (advance s); String str
  | Token.Bool b     -> ignore (advance s); Bool b
  | Token.Ident name -> ignore (advance s); PVar name
  | Token.Underscore -> ignore (advance s); Wild
  | Token.LParen     ->
    ignore (advance s);
    if peek s = Token.RParen then (ignore (advance s); Unit)
    else begin
      let p = pat_ s in
      if peek s = Token.Comma then begin
        let ps = ref [p] in
        while peek s = Token.Comma do
          ignore (advance s); ps := !ps @ [pat_ s]
        done;
        expect s Token.RParen; PTuple !ps
      end else if peek s = Token.Colon then
        raise (ParseError (Printf.sprintf
          "%s'(x : xs)' is Haskell; a wand cons pattern is written in \
           square brackets: [x : xs]" (loc_prefix s)))
      else begin
        expect s Token.RParen;
        (* (bare_var) signals single-constructor unwrap; complex patterns stay transparent *)
        match p with PVar _ -> PTuple [p] | _ -> p
      end
    end
  | Token.LBracket ->
    ignore (advance s); list_pat_ s
  | Token.Upper name ->
    ignore (advance s);
    if peek_named_args s then begin
      ignore (advance s); (* consume LParen *)
      let fields = ref [] in
      if peek s <> Token.RParen then begin
        let parse_field () =
          let fname = expect_ident s in
          expect s Token.Eq;
          fields := !fields @ [(fname, pat_ s)]
        in
        parse_field ();
        while peek s = Token.Comma do ignore (advance s); parse_field () done
      end;
      expect s Token.RParen;
      PConstrNamed (name, !fields)
    end else if peek s = Token.LParen then begin
      ignore (advance s); (* consume LParen *)
      if peek s = Token.RParen then (ignore (advance s); PConstr (name, []))
      else begin
        let pats = ref [pat_ s] in
        while peek s = Token.Comma do
          ignore (advance s); pats := !pats @ [pat_ s]
        done;
        expect s Token.RParen;
        (* Parentheses group a tuple; several arguments are written by
           juxtaposition. Mirrors the expression side. *)
        match !pats with
        | (_ :: _ :: _ as ps) -> PConstr (name, [PTuple ps])
        | pats -> PConstr (name, pats)
      end
    end else begin
      let args = ref [] in
      while is_pat_atom_start (peek s) do
        args := !args @ [pat_atom_ s]
      done;
      PConstr (name, !args)
    end
  | t ->
    let loc = loc_prefix s in
    raise (ParseError (Format.asprintf "%sunexpected token in pattern: %a%s"
      loc Token.pp t (keyword_hint t)))

and pat_atom_ s =
  match peek s with
  | Token.Int n      -> ignore (advance s); (Int n : pat)
  | Token.Float f    -> ignore (advance s); Float f
  | Token.String str -> ignore (advance s); String str
  (* A backtick string is a string; a pattern has no interpolation to keep
     apart, so it needs no separate form. *)
  | Token.RawStr str -> ignore (advance s); String str
  | Token.Bool b     -> ignore (advance s); Bool b
  | Token.Ident name -> ignore (advance s); PVar name
  | Token.Underscore -> ignore (advance s); Wild
  | Token.Upper name -> ignore (advance s); PConstr (name, [])
  | Token.LParen     ->
    ignore (advance s);
    if peek s = Token.RParen then (ignore (advance s); Unit)
    else begin
      let p = pat_ s in
      if peek s = Token.Comma then begin
        let ps = ref [p] in
        while peek s = Token.Comma do
          ignore (advance s); ps := !ps @ [pat_ s]
        done;
        expect s Token.RParen; PTuple !ps
      end else if peek s = Token.Colon then
        raise (ParseError (Printf.sprintf
          "%s'(x : xs)' is Haskell; a wand cons pattern is written in \
           square brackets: [x : xs]" (loc_prefix s)))
      else (expect s Token.RParen; p)
    end
  | Token.LBracket ->
    ignore (advance s); list_pat_ s
  | t ->
    let loc = loc_prefix s in
    raise (ParseError (Format.asprintf "%sunexpected token in pattern: %a%s"
      loc Token.pp t (keyword_hint t)))

and list_pat_ s =
  (* [ already consumed *)
  if peek s = Token.RBracket then (ignore (advance s); PList [])
  else begin
    (* Disambiguate: [ident = pat, ...] is PMap; otherwise PList/PCons *)
    let is_map =
      match peek s with
      | Token.Ident _ | Token.String _ ->
        let saved = s.pos in
        ignore (advance s);
        let result = peek s = Token.Eq in
        s.pos <- saved;
        result
      | _ -> false
    in
    if is_map then begin
      let parse_entry () =
        let key = match advance s with
          | Token.Ident k  -> k
          | Token.String k -> k
          | t -> raise (ParseError (Format.asprintf "expected map key, got %a" Token.pp t))
        in
        expect s Token.Eq;
        (key, pat_ s)
      in
      let entries = ref [parse_entry ()] in
      while peek s = Token.Comma do
        ignore (advance s); entries := !entries @ [parse_entry ()]
      done;
      expect s Token.RBracket;
      PMap !entries
    end else begin
      let first = pat_ s in
      if peek s = Token.Colon then begin
        ignore (advance s);
        (* Chain further cons cells: [a : b : c : t] is PCons(a, PCons(b,
           PCons(c, t))), not just a single cons with a flat tail. *)
        let rec parse_cons_tail () =
          let p = pat_ s in
          if peek s = Token.Colon then begin
            ignore (advance s);
            PCons (p, parse_cons_tail ())
          end else p
        in
        let tl = parse_cons_tail () in
        expect s Token.RBracket;
        PCons (first, tl)
      end else begin
        let pats = ref [first] in
        while peek s = Token.Comma do
          ignore (advance s); pats := !pats @ [pat_ s]
        done;
        expect s Token.RBracket;
        PList !pats
      end
    end
  end

let builtin_types = [
  "Int"; "Float"; "String"; "Bool"; "Unit"; "Path";
  "Date"; "Time"; "DateTime"; "Duration"; "Url";
  "IPv4"; "CIDR"; "Port"; "Version"; "Size"
]

let is_type_atom_start = function
  | Token.Upper _ | Token.LParen | Token.TypeVar _ -> true
  | _ -> false

let rec parse_type_atom s =
  let loc = loc_prefix s in
  match advance s with
  | Token.Upper name -> Ast.TEName name
  | Token.TypeVar name -> Ast.TEVar name
  | Token.LParen ->
    let first = parse_type_expr s in
    if peek s = Token.Comma then begin
      let rest = ref [] in
      while peek s = Token.Comma do
        ignore (advance s); rest := !rest @ [parse_type_expr s]
      done;
      expect s Token.RParen;
      Ast.TETuple (first :: !rest)
    end else begin
      expect s Token.RParen; first   (* pure grouping *)
    end
  | Token.Ident name ->
    raise (ParseError (Printf.sprintf "%sexpected type name, got '%s'%s"
      loc name (Util.hint name builtin_types)))
  | t -> raise (ParseError (Format.asprintf "%sexpected type name, got %a" loc Token.pp t))

and parse_type_app s =
  let left = ref (parse_type_atom s) in
  while is_type_atom_start (peek s) && not (newline_breaks_expr s) do
    left := Ast.TEApp (!left, parse_type_atom s)
  done;
  !left

and parse_type_expr s =
  let left = parse_type_app s in
  if peek s = Token.Arrow then
    (ignore (advance s); Ast.TEFun (left, parse_type_expr s))
  else left

(* ── Expression parsing (Pratt) ───────────────────────────────────────────── *)

let rec expr_ bp s =
  let left = ref (atom_ s) in
  let continue_ = ref true in
  while !continue_ do
    let had_newline = newline_breaks_expr s in
    let t = peek s in
    let bp' = lbp t in
    if bp' > bp then begin
      ignore (advance s);
      left := infix_ !left t s
    end else if is_atom_start t && 70 > bp && not s.in_contract
            && not had_newline then
      left := App (!left, atom_ s)
    else
      continue_ := false
  done;
  !left

and infix_ left op s =
  match op with
  | Token.PipeArrow  -> BinOp ("|>", left, expr_ 10 s)
  | Token.Colon      -> BinOp (":", left, expr_ 14 s)
  | Token.PipePipe  -> BinOp ("||", left, expr_ 20 s)
  | Token.AmpAmp    -> BinOp ("&&", left, expr_ 30 s)
  | Token.EqEq      -> BinOp ("==", left, expr_ 40 s)
  | Token.BangEq    -> BinOp ("!=", left, expr_ 40 s)
  | Token.Lt        -> BinOp ("<",  left, expr_ 40 s)
  | Token.Gt        -> BinOp (">",  left, expr_ 40 s)
  | Token.LtEq      -> BinOp ("<=", left, expr_ 40 s)
  | Token.GtEq      -> BinOp (">=", left, expr_ 40 s)
  | Token.Plus      -> BinOp ("+",  left, expr_ 50 s)
  | Token.Minus     -> BinOp ("-",  left, expr_ 50 s)
  | Token.PlusPlus  -> BinOp ("++", left, expr_ 50 s)
  | Token.Star      -> BinOp ("*",   left, expr_ 60 s)
  | Token.Slash     -> BinOp ("/",   left, expr_ 60 s)
  | Token.Percent   -> BinOp ("%",   left, expr_ 60 s)
  | Token.Dot       -> Field (left, expect_ident s)
  | t -> raise (ParseError (Format.asprintf "unexpected infix: %a" Token.pp t))

and atom_base_ s =
  let loc = loc_prefix s in
  match advance s with
  | Token.Int n      -> (Int n : expr)
  | Token.Float f    -> Float f
  | Token.String str -> String str
  | Token.Bool b     -> Bool b
  | Token.Path p     -> Path p
  | Token.Glob g     -> Glob g
  | Token.Date d     -> Date d
  | Token.Time t     -> Time t
  | Token.DateTime d -> DateTime d
  | Token.Duration d -> Duration d
  | Token.Url u      -> Url u
  | Token.IPv4 a     -> IPv4 a
  | Token.CIDR c     -> CIDR c
  | Token.Port n     -> Port n
  | Token.Version v  -> Version v
  | Token.Size sz    -> Size sz
  | Token.Ident name  -> Var name
  | Token.Upper name  ->
    if peek_named_args s then begin
      ignore (advance s); (* consume LParen *)
      let fields = ref [] in
      if peek s <> Token.RParen then begin
        let parse_field () =
          let fname = expect_ident s in
          expect s Token.Eq;
          fields := !fields @ [(Some fname, expr_ 0 s)]
        in
        parse_field ();
        while peek s = Token.Comma do ignore (advance s); parse_field () done
      end;
      expect s Token.RParen;
      ConstrApp (name, !fields)
    end else if peek s = Token.LParen then begin
      ignore (advance s); (* consume LParen *)
      if peek s = Token.RParen then (ignore (advance s); App (Constr name, Unit))
      else begin
        let args = ref [expr_ 0 s] in
        while peek s = Token.Comma do
          ignore (advance s); args := !args @ [expr_ 0 s]
        done;
        expect s Token.RParen;
        (* `Ctor (a, b)` is the constructor applied to one tuple. Several
           arguments are written by juxtaposition, `Ctor a b`, as everywhere
           else in the language.

           This used to depend on the constructor's declared arity, which the
           parser only knew for types declared in the same file -- so the
           same expression meant different things depending on where its type
           lived, and `Some (a, b)` was read as two arguments in every file
           but Option's own. *)
        match !args with
        | (_ :: _ :: _ as es) -> App (Constr name, Tuple es)
        | args ->
          List.fold_left (fun acc arg -> App (acc, arg)) (Constr name) args
      end
    end else
      Constr name
  | Token.EnvVar name -> EnvVar name
  | Token.Hole        -> Hole
  | Token.Minus      -> UnOp ("-", expr_ 65 s)
  | Token.Bang       -> UnOp ("!", expr_ 65 s)
  | Token.LParen     ->
    if peek s = Token.RParen then (ignore (advance s); Unit)
    else begin
      let e_loc = peek_loc s in
      let e = expr_ 0 s in
      if peek s = Token.Comma then begin
        let es = ref [e] in
        while peek s = Token.Comma do
          ignore (advance s); es := !es @ [expr_ 0 s]
        done;
        expect s Token.RParen; Tuple !es
      end else if peek s = Token.Semicolon then begin
        (* `(e1; e2; e3)` -- statements in sequence, valuing the last. The
           parentheses are what make it unambiguous: outside a bracket a
           newline already separates statements, and juxtaposition means a
           bare `;` could not tell "next statement" from "next argument"
           anywhere an application may continue. A trailing `;` before the
           `)` is allowed. Nested to the right so every discarded statement
           is a Seq's own first child, which is where the typechecker
           records its type for the discarded-Result lint. *)
        let es = ref [Located (e_loc, e)] in
        while peek s = Token.Semicolon do
          ignore (advance s);
          if peek s <> Token.RParen then begin
            let loc = peek_loc s in
            es := Located (loc, expr_ 0 s) :: !es
          end
        done;
        expect s Token.RParen;
        (match !es with
         | last :: rev_init ->
           List.fold_left (fun acc e -> Seq (e, acc)) last rev_init
         | [] -> assert false)
      end else (expect s Token.RParen; e)
    end
  | Token.LBracket -> list_ s
  | Token.Let      -> let_ s
  | Token.If       -> if_ s
  | Token.Match    -> match_ s
  | Token.Fn       -> fn_ s
  | Token.Import   ->
    (match advance s with
     | Token.Upper n -> ImportExpr (Ast.StdlibModule n)
     | Token.Path p  -> ImportExpr (Ast.UserPath p)
     | t -> raise (ParseError (Format.asprintf "%sexpected module name or path after import, got %a"
                loc Token.pp t)))
  | Token.Result   -> Var "result"
  | Token.Dollar   ->
    expect s Token.LParen;
    let e = expr_ 0 s in
    expect s Token.RParen;
    RunCmd (e, s.shell_allow)
  | Token.RunCmdRaw (parts, tail) ->
    let parse_parts = List.map (fun (lit, src, raw) ->
      let toks = Lexer.tokenize src in
      let s2 = make toks in
      (lit, expr_ 0 s2, raw)
    ) parts in
    if parse_parts = [] then RunCmd (String tail, s.shell_allow)
    else RunCmd (CmdInterp (parse_parts, tail), s.shell_allow)
  | Token.RunQueryRaw (parts, tail) ->
    let parse_parts = List.map (fun (lit, src, raw) ->
      let toks = Lexer.tokenize src in
      let s2 = make toks in
      (lit, expr_ 0 s2, raw)
    ) parts in
    if parse_parts = [] then RunQuery (String tail, s.shell_allow)
    else RunQuery (CmdInterp (parse_parts, tail), s.shell_allow)
  | Token.Regex (pat, flags) -> RegexLit (pat, flags)
  | Token.InterpStr (parts, tail) ->
    let parsed = List.map (fun (lit, src) ->
      let toks = Lexer.tokenize src in
      let s2 = make toks in
      (lit, expr_ 0 s2)
    ) parts in
    Interp (parsed, tail)
  | Token.RawStr str -> RawString str
  | Token.RawInterpStr (parts, tail) ->
    let parsed = List.map (fun (lit, src) ->
      let toks = Lexer.tokenize src in
      let s2 = make toks in
      (lit, expr_ 0 s2)
    ) parts in
    RawInterp (parsed, tail)
  | Token.Handle -> parse_handle_ s
  | Token.With   -> parse_with_ s
  | Token.Try    ->
    let body = expr_ 0 s in
    if peek s = Token.With && s.with_owners = 0 then
      raise (ParseError (Printf.sprintf
        "%s'try ... with' is OCaml; wand's try takes no cases. 'try e' \
         yields a Result to match on -- and 'handle ... with' is what \
         intercepts effects." (loc_prefix s)))
    else Ast.Try body
  | t -> raise (ParseError (Format.asprintf "%sunexpected token: %a%s"
      loc Token.pp t (keyword_hint t)))

(* `.field` binds tightly to the atom it immediately follows -- applied right
   after every atom_base_ call so `f x.y` parses as `f (x.y)`, not `(f x).y`
   (which is what plain infix-operator precedence would give, since by the
   time the Pratt loop in expr_ reaches `.`, `left` already has the whole
   application chain accumulated). *)
and postfix_field_ s e =
  let e = ref e in
  while peek s = Token.Dot do
    ignore (advance s);
    e := Field (!e, expect_ident s)
  done;
  !e

and atom_ s = postfix_field_ s (atom_base_ s)

and list_ s =
  (* [ already consumed *)
  if peek s = Token.RBracket then (ignore (advance s); List [])
  else begin
    (* Disambiguate: [ident = expr, ...] is MapLit; otherwise List *)
    let is_map =
      match peek s with
      | Token.Ident _ | Token.String _ ->
        let saved = s.pos in
        ignore (advance s);
        let result = peek s = Token.Eq in
        s.pos <- saved;
        result
      | _ -> false
    in
    if is_map then begin
      let parse_entry () =
        let key = match advance s with
          | Token.Ident k  -> k
          | Token.String k -> k
          | t -> raise (ParseError (Format.asprintf "expected map key, got %a" Token.pp t))
        in
        expect s Token.Eq;
        (key, expr_ 0 s)
      in
      let entries = ref [parse_entry ()] in
      while peek s = Token.Comma do
        ignore (advance s); entries := !entries @ [parse_entry ()]
      done;
      expect s Token.RBracket;
      MapLit !entries
    end else begin
      let elems = ref [expr_ 0 s] in
      while peek s = Token.Comma do
        ignore (advance s); elems := !elems @ [expr_ 0 s]
      done;
      expect s Token.RBracket;
      List !elems
    end
  end

and parse_body s =
  let loc = peek_loc s in
  let e = ref (Located (loc, expr_ 0 s)) in
  while is_expr_start (peek s) do
    let loc = peek_loc s in
    e := Seq (!e, Located (loc, expr_ 0 s))
  done;
  !e

(* Parses `params (: T)? = body`, with optional multi-equation clauses
   repeating `name`, for a binding already-consumed `name`. Returns the
   final (params, body) pair — used both for the first binding in a
   `let ... and ...` group and each subsequent `and name ...` clause.
   Requires at least one parameter: plain-value mutual recursion isn't
   supported in a strict language (self-reference only works through a
   function's laziness), so `and`-bound members must be functions. *)
and parse_fn_binding s name =
  let loc = loc_prefix s in
  let params = ref [] in
  while is_pat_atom_start (peek s) do
    params := !params @ [pat_atom_ s]
  done;
  if !params = [] then
    raise (ParseError (Printf.sprintf
      "%s'%s' in a mutually-recursive 'and' group must take at least one \
       parameter — plain recursive values aren't supported" loc name));
  let annot = if peek s = Token.Colon then
    (ignore (advance s); Some (parse_type_expr s))
  else None in
  expect s Token.Eq;
  let body_loc = peek_loc s in
  let body = Located (body_loc, parse_contract_body s) in
  let body = match annot with
    | Some te -> Located (body_loc, Annot (te, body))
    | None -> body
  in
  let arity = List.length !params in
  let eqs = ref [(!params, body)] in
  let more = ref true in
  while !more do
    let saved = s.pos in
    (try
      (* A continuation clause may optionally repeat `let` (matching the
         top-level `let f 0 = .. / let f n = ..` syntax) or omit it (the
         original local shorthand) -- both are accepted. *)
      (match peek s with Token.Let -> ignore (advance s) | _ -> ());
      (match peek s with
       | Token.Ident n when n = name -> ignore (advance s)
       | _ -> raise Exit);
      let ps = ref [] in
      while is_pat_atom_start (peek s) do ps := !ps @ [pat_atom_ s] done;
      if List.length !ps <> arity then raise Exit;
      (match peek s with Token.Eq -> ignore (advance s) | _ -> raise Exit);
      let b_loc = peek_loc s in
      let b = Located (b_loc, parse_contract_body s) in
      eqs := !eqs @ [(!ps, b)]
    with Exit -> s.pos <- saved; more := false)
  done;
  match !eqs with
  | [(ps, b)] -> (ps, b)
  | eqs ->
    let fresh = List.init arity (fun i -> Printf.sprintf "_p%d" i) in
    let scrutinee = match fresh with
      | [v] -> Var v
      | vs  -> Tuple (List.map (fun v -> Var v) vs)
    in
    let cases = List.map (fun (pats, b) ->
      let pat = match pats with [p] -> p | ps -> PTuple ps in
      (pat, None, b)
    ) eqs in
    (List.map (fun v -> PVar v) fresh, Match (scrutinee, cases))

and let_ s =
  (* let already consumed *)
  let p = pat_ s in
  let consume_rest () =
    if peek s = Token.In then begin
      ignore (advance s);
      let loc = peek_loc s in
      Located (loc, expr_ 0 s)
    end
    else if is_expr_start (peek s) then parse_body s
    else Unit
  in
  match p with
  | PVar "rec" when is_pat_atom_start (peek s) ->
    raise (ParseError (Printf.sprintf
      "%s'let rec' is OCaml; a wand let is already recursive -- drop the \
       'rec' (mutual recursion is 'let f ... and g ...')" (loc_prefix s)))
  | PVar name when peek s <> Token.Eq && is_pat_atom_start (peek s) ->
    (* function shorthand: let f params = body, with optional multi-equation
       and optional mutually-recursive `and` group *)
    let (params, body) = parse_fn_binding s name in
    if peek s = Token.And then begin
      let bindings = ref [(name, params, body)] in
      while peek s = Token.And do
        ignore (advance s);
        let and_loc = loc_prefix s in
        let name2 = match advance s with
          | Token.Ident n -> n
          | t -> raise (ParseError (Format.asprintf
              "%sexpected identifier after 'and', got %a" and_loc Token.pp t))
        in
        let (params2, body2) = parse_fn_binding s name2 in
        bindings := !bindings @ [(name2, params2, body2)]
      done;
      let rest = consume_rest () in
      LetRec (!bindings, rest)
    end else begin
      let rest = consume_rest () in
      Let (PVar name, Fn (params, body), rest)
    end
  | PVar name when peek s <> Token.Eq ->
    (* annotated value binding: let x : T = e *)
    let annot = if peek s = Token.Colon then
      (ignore (advance s); Some (parse_type_expr s))
    else None in
    expect s Token.Eq;
    let body_loc = peek_loc s in
    let body = Located (body_loc, parse_contract_body s) in
    let e = match annot with Some te -> Annot (te, body) | None -> body in
    let rest = consume_rest () in
    Let (PVar name, e, rest)
  | _ ->
    expect s Token.Eq;
    let e1_loc = peek_loc s in
    let e1 = Located (e1_loc, expr_ 0 s) in
    let e2 = consume_rest () in
    Let (p, e1, e2)

and if_ s =
  (* if already consumed *)
  let cond_loc = peek_loc s in
  let cond   = Located (cond_loc, expr_ 0 s) in
  expect s Token.Then;
  let then_loc = peek_loc s in
  let then_ = Located (then_loc, expr_ 0 s) in
  (* A one-armed `if` is `else ()`. Scripting is full of conditionals that
     do something or nothing -- reporting a count only when there is one --
     and writing the empty branch out adds a line that says nothing. The
     branch still has to be `Unit`, because the two arms of an `if` are one
     expression and the missing one can only be `()`. *)
  if peek s <> Token.Else then If (cond, then_, Unit)
  else begin
    ignore (advance s);
    let else_loc = peek_loc s in
    let else_ = Located (else_loc, expr_ 0 s) in
    If (cond, then_, else_)
  end

and match_ s =
  (* match already consumed *)
  s.with_owners <- s.with_owners + 1;
  let scrutinee = expr_ 0 s in
  expect s Token.With;
  s.with_owners <- s.with_owners - 1;
  let arms_loc = loc_prefix s in
  let cases = ref [] in
  let continue_ = ref true in
  while !continue_ do
    if peek s = Token.Pipe then begin
      ignore (advance s);
      let p = pat_ s in
      let guard =
        if peek s = Token.When then begin
          ignore (advance s);
          let loc = peek_loc s in
          Some (Located (loc, expr_ 0 s))
        end else None
      in
      expect s Token.Arrow;
      let body_loc = peek_loc s in
      let body = Located (body_loc, expr_ 0 s) in
      cases := !cases @ [(p, guard, body)]
    end else
      continue_ := false
  done;
  (* A match with no arms has no value for any input, so nothing it could
     mean is worth inferring. Left alone it typechecked as 'a -> 'b and
     bound a name whose body had silently gone missing. *)
  if !cases = [] then
    raise (ParseError (Format.asprintf
      "%smatch has no cases; each begins with '|', as in `| Some x -> x`"
      arms_loc));
  Match (scrutinee, !cases)

and contract_expr_ s =
  s.in_contract <- true;
  Fun.protect ~finally:(fun () -> s.in_contract <- false) (fun () -> expr_ 0 s)

and parse_contract_body s =
  let reqs = ref [] in
  let ens  = ref [] in
  let continue_ = ref true in
  while !continue_ do
    match peek s with
    | Token.Requires ->
      ignore (advance s);
      let loc = peek_loc s in
      reqs := !reqs @ [Located (loc, contract_expr_ s)]
    | Token.Ensures  ->
      ignore (advance s);
      let loc = peek_loc s in
      ens := !ens @ [Located (loc, contract_expr_ s)]
    | _ -> continue_ := false
  done;
  let body_loc = peek_loc s in
  let body = Located (body_loc, expr_ 0 s) in
  if !reqs = [] && !ens = [] then body
  else Ast.Contract (!reqs, !ens, body)

and fn_ s =
  (* fn already consumed *)
  let params = ref [] in
  while is_pat_atom_start (peek s) do
    params := !params @ [pat_atom_ s]
  done;
  expect s Token.Arrow;
  let body_loc = peek_loc s in
  Fn (!params, Located (body_loc, parse_contract_body s))

(* ── Resource bracket ─────────────────────────────────────────────────────── *)

(* `with <resource> as <pat> -> <body>`. Unambiguous with `match ... with`,
   which only ever reaches its `with` after a scrutinee, never at the start
   of an expression. The resource expression stops at `as`, so it is parsed
   at precedence 0 and the keyword terminates it. *)
and parse_with_ s =
  (* with already consumed *)
  let resource = expr_ 0 s in
  expect s Token.As;
  let p = pat_ s in
  expect s Token.Arrow;
  let body = expr_ 0 s in
  Ast.With (resource, p, body)

(* ── Handle expression ────────────────────────────────────────────────────── *)

and parse_handle_ s =
  (* handle already consumed *)
  s.with_owners <- s.with_owners + 1;
  let body = expr_ 0 s in
  expect s Token.With;
  s.with_owners <- s.with_owners - 1;
  let cases = ref [] in
  let continue_ = ref true in
  while !continue_ do
    if peek s = Token.Pipe then begin
      ignore (advance s);
      let case = match peek s with
        | Token.Return ->
          ignore (advance s);
          let p = pat_atom_ s in
          expect s Token.Arrow;
          let b_loc = peek_loc s in
          let b = Located (b_loc, expr_ 0 s) in
          Ast.ReturnCase (p, b)
        (* `FS!read_file` reaches here as the Upper token "FS!" followed by an
           identifier, since `!` is a suffix character. Joining them gives the
           operation name, which is the public call with a `!` where its dot
           would be: you call FS.read_file, you intercept FS!read_file. *)
        | Token.Upper family
          when String.length family > 1
            && family.[String.length family - 1] = '!' ->
          ignore (advance s);
          let verb = expect_ident s in
          let op_name = family ^ verb in
          let arg_pat = pat_atom_ s in
          let cont_name = expect_cont_name s in
          expect s Token.Arrow;
          let b_loc = peek_loc s in
          let b = Located (b_loc, expr_ 0 s) in
          Ast.EffectCase (op_name, arg_pat, cont_name, b)
        | Token.Ident op_name ->
          ignore (advance s);
          let arg_pat = pat_atom_ s in
          let cont_name = expect_ident s in
          expect s Token.Arrow;
          let b_loc = peek_loc s in
          let b = Located (b_loc, expr_ 0 s) in
          Ast.EffectCase (op_name, arg_pat, cont_name, b)
        | t ->
          raise (ParseError (Format.asprintf "%sunexpected token in handler case: %a"
            (loc_prefix s) Token.pp t))
      in
      cases := !cases @ [case]
    end else
      continue_ := false
  done;
  Ast.Handle (body, !cases)

let collapse_multi_equation arity eqs : Ast.pat list * Ast.expr =
  match eqs with
  | [(p, b)] -> (p, b)
  | eqs ->
    let fresh = List.init arity (fun i -> Printf.sprintf "_p%d" i) in
    let scrutinee = match fresh with
      | [v] -> Ast.Var v
      | vs  -> Ast.Tuple (List.map (fun v -> Ast.Var v) vs)
    in
    let cases = List.map (fun (pats, body) ->
      let pat = match pats with [p] -> p | ps -> Ast.PTuple ps in
      (pat, None, body)
    ) eqs in
    (List.map (fun v -> Ast.PVar v) fresh, Ast.Match (scrutinee, cases))

let build_multi_equation name arity eqs =
  let (p, b) = collapse_multi_equation arity eqs in
  Ast.TLLet (name, p, b)

(* Record a completed top-level function, rejecting a second definition of a
   name already defined. A function's equations are parsed as one contiguous
   group, so reaching this a second time means another `let` for the same
   name appeared after something else came between -- which used to either
   merge into the earlier definition or silently shadow it, depending on
   arity, with nothing at the definition site to say which. *)
let note_top_fn s loc name arity =
  match Hashtbl.find_opt s.top_fns name with
  | Some prev_arity ->
    raise (ParseError (Printf.sprintf
      "%s'%s' is already defined above%s. Equations for a function must be \
       consecutive — move this one up beside the others, or rename it"
      loc name
      (if prev_arity = arity then ""
       else Printf.sprintf " (taking %d parameter%s)" prev_arity
              (if prev_arity = 1 then "" else "s"))))
  | None -> Hashtbl.replace s.top_fns name arity

(* Parses `params (: T)? = body` plus any `let name ...` multi-equation
   continuations, for a NEW name introduced by `and` in a top-level
   mutually-recursive group. Requires at least one parameter — plain-value
   mutual recursion isn't supported in a strict language (see the local
   `parse_fn_binding` above for why). *)
let parse_top_fn_binding s name =
  let loc = loc_prefix s in
  let params = ref [] in
  while is_pat_atom_start (peek s) do
    params := !params @ [pat_atom_ s]
  done;
  if !params = [] then
    raise (ParseError (Printf.sprintf
      "%s'%s' in a mutually-recursive 'and' group must take at least one \
       parameter — plain recursive values aren't supported" loc name));
  let annot = if peek s = Token.Colon then
    (ignore (advance s); Some (parse_type_expr s))
  else None in
  expect s Token.Eq;
  let body_loc = peek_loc s in
  let body = Ast.Located (body_loc, parse_contract_body s) in
  let body = match annot with
    | Some te -> Ast.Located (body_loc, Ast.Annot (te, body))
    | None -> body
  in
  let arity = List.length !params in
  let eqs = ref [(!params, body)] in
  let more = ref true in
  while !more do
    let saved = s.pos in
    (try
      (match peek s with Token.Let -> ignore (advance s) | _ -> raise Exit);
      (match peek s with
       | Token.Ident n when n = name -> ignore (advance s)
       | _ -> raise Exit);
      let ps = ref [] in
      while is_pat_atom_start (peek s) do ps := !ps @ [pat_atom_ s] done;
      if List.length !ps <> arity then raise Exit;
      (match peek s with Token.Eq -> ignore (advance s) | _ -> raise Exit);
      let b_loc = peek_loc s in
      let b = Ast.Located (b_loc, parse_contract_body s) in
      eqs := !eqs @ [(!ps, b)]
    with Exit -> s.pos <- saved; more := false)
  done;
  collapse_multi_equation arity !eqs

(* ── Public API ───────────────────────────────────────────────────────────── *)

let parse_expr tokens =
  let s = make tokens in
  expr_ 0 s

let parse_type_def s =
  (* type already consumed *)
  let type_name =
    let loc = loc_prefix s in
    match advance s with
    | Token.Upper n -> n
    | t -> raise (ParseError (Format.asprintf "%sexpected type name, got %a" loc Token.pp t))
  in
  let params = ref [] in
  while (match peek s with Token.TypeVar _ -> true | _ -> false) do
    (match advance s with
     | Token.TypeVar n -> params := !params @ [n]
     | _ -> assert false)
  done;
  let parse_ctor_fields () =
    (* Peek: Upper -> space-separated positional type atoms, no parens.
       LParen + Ident -> named-field record shorthand: (ident : Type, ...).
       LParen + other -> single field needing grouping/tupling: (List Int),
         (Int, Int). *)
    match peek s with
    (* The newline check belongs on the first payload as much as the rest: a
       constructor without one would otherwise take the next line's type name
       as its payload, so `type Color = Red | Green` followed by a line
       starting with an uppercase name silently became `Green <that>`. *)
    | (Token.Upper _ | Token.TypeVar _) when not (newline_breaks_expr s) ->
      let fields = ref [(None, parse_type_atom s)] in
      while is_type_atom_start (peek s) && not (newline_breaks_expr s) do
        fields := !fields @ [(None, parse_type_atom s)]
      done;
      !fields
    | Token.LParen ->
      let saved = s.pos in
      ignore (advance s);
      (match peek s with
       | Token.Ident _ ->
         let parse_named () =
           let fname = expect_ident s in
           expect s Token.Colon;
           (* An applied type -- `List String`, `Option Node` -- reads as one
              field type. The comma and the closing paren are not type atoms,
              so the application stops where the field does. Positional fields
              stay atoms: `Pair Int Int` is two of them, not one applied to
              the other. *)
           let ftype = parse_type_app s in
           (Some fname, ftype)
         in
         let first = parse_named () in
         let rest = ref [] in
         while peek s = Token.Comma do
           ignore (advance s);
           rest := !rest @ [parse_named ()]
         done;
         expect s Token.RParen;
         first :: !rest
       | _ ->
         s.pos <- saved;
         [(None, parse_type_atom s)])
    | _ -> []
  in
  (* Single-constructor shorthand: type Foo (fields...) desugars to type Foo = Foo (fields...) *)
  if peek s = Token.LParen then begin
    let fields = parse_ctor_fields () in
    Ast.Variants (type_name, !params, [{ Ast.name = type_name; fields }])
  end else begin
    expect s Token.Eq;
    let parse_ctor () =
      let name =
        let loc = loc_prefix s in
        match advance s with
        | Token.Upper n -> n
        | t -> raise (ParseError (Format.asprintf "%sexpected constructor name, got %a" loc Token.pp t))
      in
      let fields = parse_ctor_fields () in
      { Ast.name; fields }
    in
    let ctors = ref [parse_ctor ()] in
    while peek s = Token.Pipe do
      ignore (advance s);
      ctors := !ctors @ [parse_ctor ()]
    done;
    Ast.Variants (type_name, !params, !ctors)
  end

(* Shared by `parse_program` and `parse_program_with_locs`: every loop
   iteration appends at most one item to `items` (via `items := !items @
   [x]`), so a physical-inequality check on the list before/after an
   iteration cheaply detects "an item was added" without re-walking the
   list. `on_item` is invoked with (start loc, loc of the item's last
   consumed token) whenever that happens; `parse_program` passes a no-op,
   `parse_program_with_locs` records into a side list. *)
(* `uses {Shell, FS.Write}` -- the file's declared bound. It is the first
   item on purpose: a reviewer who has to search for it gains nothing over
   having no manifest at all, so its position is part of the syntax rather
   than a convention. Comments and a shebang may precede it. *)
let parse_manifest s =
  let loc = peek_loc s in
  ignore (advance s);              (* uses *)
  expect s Token.LBrace;
  let labels = ref [] in
  (* `Shell(git, curl)` -- the binaries the file may invoke. Entries are
     bare when they lex as one word or one path; anything else is quoted. *)
  let read_shell_args () =
    ignore (advance s);            (* ( *)
    if peek s = Token.RParen then
      raise (ParseError (Printf.sprintf
        "%sShell() admits nothing -- a file that runs no commands drops the \
         label instead" (loc_prefix s)));
    let args = ref [] in
    let read_arg () =
      let add word =
        if List.mem word !args then
          raise (ParseError (Printf.sprintf
            "%s'%s' is already in this Shell(...) list" (loc_prefix s) word));
        args := !args @ [word]
      in
      let (first, floc) = advance_loc s in
      match first with
      | Token.String w -> add w
      | Token.Ident w0 | Token.Path w0 ->
        (* `docker-compose` arrives as `docker`, `-`, `compose`, and
           `demos/probe.sh` as an ident then a path -- inside $() a name
           is raw text, and the manifest should read the same spelling.
           Fragments are rejoined only when byte-adjacent, so a genuinely
           spaced `a - b` stays an error. *)
        let buf = Buffer.create 16 in
        Buffer.add_string buf w0;
        let end_ = ref (floc.Token.offset + String.length w0) in
        let rec join () =
          match Shell_scan.fragment (peek s) with
          | Some frag when (peek_loc s).Token.offset = !end_ ->
            ignore (advance s);
            Buffer.add_string buf frag;
            end_ := !end_ + String.length frag;
            join ()
          | _ -> ()
        in
        join ();
        add (Buffer.contents buf)
      | t -> raise (ParseError (Format.asprintf
          "%sexpected a binary name in Shell(...), got %a -- quote a name \
           wand cannot lex as one: Shell(git, \"7zip\")"
          (loc_prefix s) Token.pp t))
    in
    read_arg ();
    while peek s = Token.Comma do ignore (advance s); read_arg () done;
    expect s Token.RParen;
    !args
  in
  let read_label () =
    let rec parts acc =
      let part = match advance s with
        | Token.Upper u -> u
        | t -> raise (ParseError (Format.asprintf
            "%sexpected an effect name in the manifest, got %a"
            (loc_prefix s) Token.pp t))
      in
      let acc = acc @ [part] in
      if peek s = Token.Dot then (ignore (advance s); parts acc) else acc
    in
    let name = String.concat "." (parts []) in
    let allow =
      if peek s <> Token.LParen then None
      else if name = "Shell" then Some (read_shell_args ())
      else
        raise (ParseError (Printf.sprintf
          "%sonly Shell takes a list of binaries in a manifest"
          (loc_prefix s)))
    in
    labels := !labels @ [(name, allow)]
  in
  if peek s <> Token.RBrace then begin
    read_label ();
    while peek s = Token.Comma do ignore (advance s); read_label () done
  end;
  expect s Token.RBrace;
  (!labels, loc)

let looks_like_manifest s =
  match peek s with
  | Token.Ident "uses" ->
    (* `uses` is an ordinary word elsewhere; only `uses {` starts a manifest,
       and `{` begins nothing else in the language. *)
    let saved = s.pos in
    ignore (advance s);
    let is_manifest = peek s = Token.LBrace in
    s.pos <- saved;
    is_manifest
  | _ -> false

let parse_program_generic ~on_item tokens =
  let s = make tokens in
  let items = ref [] in
  let docs  = ref [] in
  let manifest = ref None in
  let pending_doc : string option ref = ref None in
  let attach_doc name =
    match !pending_doc with
    | None -> ()
    | Some d -> docs := (name, d) :: !docs; pending_doc := None
  in
  (* Before anything else: the manifest, if the file has one. *)
  if looks_like_manifest s then begin
    manifest := Some (parse_manifest s);
    s.shell_allow <-
      (match !manifest with
       | Some (labels, _) -> Option.join (List.assoc_opt "Shell" labels)
       | None -> None)
  end;
  (* Where the previous top-level item began, so an item that starts further
     in can be recognised for what it almost always is: a continuation the
     author expected to be joined to the line above. wand ends a definition
     at the end of a line, and juxtaposition cannot cross one -- an
     identifier is a perfectly good start to a new definition, so there is
     nothing to tell the two apart but the indentation. Left alone, this
     parses as separate items and surfaces much later as an unbound name
     that is plainly in scope, which is a bad way to learn a layout rule. *)
  let previous_item = ref None in
  let continue_ = ref true in
  while !continue_ do
    let start_loc = peek_loc s in
    (match !previous_item with
     (* Only where an item is about to begin on a later line: the end of the
        file carries a position too, and definitions separated by `;` sit on
        one line, where a greater column means nothing. *)
     | Some (col, end_line)
       when peek s <> Token.EOF
            && start_loc.Token.line > end_line
            && start_loc.Token.col > col
            && !items <> []
            (* Only a bare expression, which is the shape a stray argument
               takes. A definition that happens to be indented is a whole
               file's layout choice, not a mistake -- and indenting the body
               of something is how people write, so rejecting it would fire
               on correct code, which teaches a reader to stop reading
               errors. *)
            && (match peek s with
                | Token.Let | Token.LetStar | Token.Type | Token.Import
                | Token.DocComment _ -> false
                | _ -> true) ->
       raise (ParseError (Printf.sprintf
         "%d:%d: this line is indented as though it continued the definition \
          above, but a definition ends at the end of its line.\n       \
          Put the whole expression on one line, or bracket what continues it: \
          parentheses, or a leading |> for a pipeline."
         start_loc.Token.line start_loc.Token.col))
     | _ -> ());
    let before_items = !items in
    (match peek s with
    | Token.EOF -> continue_ := false
    | _ when looks_like_manifest s ->
      let (_, loc) = parse_manifest s in
      raise (ParseError (Printf.sprintf
        "%d:%d: the manifest must be the first thing in the file, before \
         everything but a shebang and comments%s"
        loc.Token.line loc.Token.col
        (if !manifest = None then "" else " (this file already has one)")))
    | Token.DocComment doc ->
      ignore (advance s);
      pending_doc := Some doc
    | Token.Newline | Token.Semicolon ->
      ignore (advance s)
    | Token.Let ->
      let saved = s.pos in
      ignore (advance s);
      (match peek s with
       | Token.LBracket | Token.LParen ->
         (* Top-level pattern destructuring: let <pat> = <expr> *)
         let p = pat_ s in
         expect s Token.Eq;
         let loc = peek_loc s in
         let body = Ast.Located (loc, parse_contract_body s) in
         if peek s = Token.In then begin
           (* Actually a let-in expression — backtrack and parse as TLExpr *)
           s.pos <- saved;
           let eloc = peek_loc s in
           let e = Ast.Located (eloc, expr_ 0 s) in
           items := !items @ [Ast.TLExpr e]
         end else
           items := !items @ [Ast.TLLetPat (p, body)]
       | Token.Ident _ | Token.Upper _ ->
         let name_loc = loc_prefix s in
         let name = match advance s with
           | Token.Ident n -> n
           | Token.Upper n -> n
           | _ -> assert false
         in
         if name = "rec" && is_pat_atom_start (peek s) then
           raise (ParseError (Printf.sprintf
             "%s'let rec' is OCaml; a wand let is already recursive -- \
              drop the 'rec' (mutual recursion is 'let f ... and g ...')"
             name_loc));
         let params = ref [] in
         while is_pat_atom_start (peek s) do
           params := !params @ [pat_atom_ s]
         done;
         let annot = if peek s = Token.Colon then
           (ignore (advance s); Some (parse_type_expr s))
         else None in
         expect s Token.Eq;
         let loc = peek_loc s in
         let body = Ast.Located (loc, parse_contract_body s) in
         let arity = List.length !params in
         if peek s = Token.In then begin
           (* let x = e in e2 — expression, not top-level binding *)
           s.pos <- saved;
           let loc = peek_loc s in
           let e = Ast.Located (loc, expr_ 0 s) in
           items := !items @ [Ast.TLExpr e]
         end else begin
         attach_doc name;
         if arity = 0 then begin
           let e = match annot with
             | Some te -> Ast.Annot (te, body)
             | None -> body
           in
           items := !items @ [Ast.TLLet (name, [], e)]
         end else begin
           let body = match annot with
             | Some te -> Ast.Located (loc, Ast.Annot (te, body))
             | None -> body
           in
           let eqs = ref [(!params, body)] in
           let more = ref true in
           while !more do
             let saved2 = s.pos in
             (try
               (match peek s with Token.Let -> ignore (advance s) | _ -> raise Exit);
               (match peek s with
                | Token.Ident n when n = name -> ignore (advance s)
                | _ -> raise Exit);
               (* Past this point the name is confirmed, so anything wrong is
                  a mistake in this equation rather than the start of an
                  unrelated binding: report it instead of backtracking into
                  a silent shadow. *)
               let eq_loc = loc_prefix s in
               let ps = ref [] in
               while is_pat_atom_start (peek s) do ps := !ps @ [pat_atom_ s] done;
               if List.length !ps <> arity then
                 raise (ParseError (Printf.sprintf
                   "%sequation %d of '%s' takes %d parameter%s, but its first \
                    equation takes %d — every equation of a function must \
                    take the same number"
                   eq_loc (List.length !eqs + 1) name
                   (List.length !ps) (if List.length !ps = 1 then "" else "s")
                   arity));
               (match peek s with Token.Eq -> ignore (advance s) | _ -> raise Exit);
               let b_loc = peek_loc s in
               let b = Ast.Located (b_loc, parse_contract_body s) in
               eqs := !eqs @ [(!ps, b)]
             with Exit -> s.pos <- saved2; more := false)
           done;
           if peek s = Token.And then begin
             let (first_params, first_body) = collapse_multi_equation arity !eqs in
             let bindings = ref [(name, first_params, first_body)] in
             while peek s = Token.And do
               ignore (advance s);
               let and_loc = loc_prefix s in
               let name2 = match advance s with
                 | Token.Ident n -> n
                 | t -> raise (ParseError (Format.asprintf
                     "%sexpected identifier after 'and', got %a" and_loc Token.pp t))
               in
               let (params2, body2) = parse_top_fn_binding s name2 in
               bindings := !bindings @ [(name2, params2, body2)]
             done;
             if peek s = Token.In then begin
               (* let f = ... and g = ... in e2 — expression, not top-level *)
               s.pos <- saved;
               let loc = peek_loc s in
               let e = Ast.Located (loc, expr_ 0 s) in
               items := !items @ [Ast.TLExpr e]
             end else begin
               List.iter (fun (n, ps, _) ->
                 note_top_fn s name_loc n (List.length ps)) !bindings;
               items := !items @ [Ast.TLLetRec !bindings]
             end
           end else begin
             note_top_fn s name_loc name arity;
             items := !items @ [build_multi_equation name arity !eqs]
           end
         end
         end  (* close the outer begin from peek s = Token.In check *)
       | _ ->
         s.pos <- saved;
         let loc = peek_loc s in
         let e = Ast.Located (loc, expr_ 0 s) in
         items := !items @ [Ast.TLExpr e])
    | Token.Import ->
      ignore (advance s);
      (match advance s with
       | Token.Upper name -> items := !items @ [Ast.TLImport (Ast.StdlibModule name)]
       | Token.Path path  -> items := !items @ [Ast.TLImport (Ast.UserPath path)]
       | t -> raise (ParseError (Format.asprintf
           "expected module name or path after import, got %a" Token.pp t)))
    | Token.Type ->
      ignore (advance s);
      let tdef = parse_type_def s in
      (match tdef with Ast.Variants (name, _, _) -> attach_doc name);
      items := !items @ [Ast.TLType tdef]
    | _ ->
      let loc = peek_loc s in
      let e = Ast.Located (loc, expr_ 0 s) in
      items := !items @ [Ast.TLExpr e];
      if peek s = Token.Eq then begin
        let rec head_ident = function
          | Ast.Located (_, inner) -> head_ident inner
          | Ast.App (f, _) -> head_ident f
          | Ast.Var id -> Some id
          | _ -> None
        in
        let inner = match e with Ast.Located (_, i) -> i | i -> i in
        (match head_ident inner with
         | Some id ->
           let hint = keyword_hint (Token.Ident id) in
           if hint <> "" then
             raise (ParseError (Format.asprintf "%sunexpected '='; did you mean 'let'?%s"
               (loc_prefix s) hint))
         | None -> ())
      end);
    if !items != before_items then begin
      let last_loc = if s.pos > 0 then snd s.tokens.(s.pos - 1) else start_loc in
      previous_item := Some (start_loc.Token.col, last_loc.Token.line);
      on_item start_loc last_loc
    end
  done;
  { Ast.items = !items; docs = !docs; manifest = !manifest }

let parse_program tokens = parse_program_generic ~on_item:(fun _ _ -> ()) tokens

let parse_program_with_locs tokens =
  let locs = ref [] in
  let prog = parse_program_generic tokens
      ~on_item:(fun start_loc end_loc -> locs := !locs @ [(start_loc, end_loc)]) in
  (prog, !locs)
