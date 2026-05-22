open Ast

exception ParseError of string

type state = {
  tokens : (Token.t * Token.loc) array;
  mutable pos : int;
  mutable in_contract : bool;
}

let make tokens = { tokens = Array.of_list tokens; pos = 0; in_contract = false }

let skip s =
  while s.pos < Array.length s.tokens
     && fst s.tokens.(s.pos) = Token.Newline do
    s.pos <- s.pos + 1
  done

let has_newline_before_next s =
  let i = ref s.pos in
  while !i < Array.length s.tokens && fst s.tokens.(!i) = Token.Newline do incr i done;
  !i > s.pos

let peek s =
  let i = ref s.pos in
  while !i < Array.length s.tokens && fst s.tokens.(!i) = Token.Newline do incr i done;
  if !i < Array.length s.tokens then fst s.tokens.(!i) else Token.EOF

let peek_loc s =
  let i = ref s.pos in
  while !i < Array.length s.tokens && fst s.tokens.(!i) = Token.Newline do incr i done;
  if !i < Array.length s.tokens then snd s.tokens.(!i) else Token.{ line = 0; col = 0 }

let advance s =
  skip s;
  if s.pos >= Array.length s.tokens then Token.EOF
  else begin
    let t = fst s.tokens.(s.pos) in
    s.pos <- s.pos + 1; t
  end

let advance_loc s =
  skip s;
  if s.pos >= Array.length s.tokens
  then (Token.EOF, Token.{ line = 0; col = 0 })
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
  let skip () = while !i < n && fst arr.(!i) = Token.Newline do incr i done in
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
  "let"; "in"; "match"; "with"; "if"; "then"; "else"; "fn";
  "type"; "start"; "import"; "when"; "of"; "and"; "or";
  "handle"; "return"
]

let keyword_hint = function
  | Token.Ident s -> Util.hint s keywords
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
  | Token.Path _ | Token.Date _ | Token.Time _ | Token.DateTime _
  | Token.Duration _ | Token.Url _ | Token.IPv4 _ | Token.CIDR _
  | Token.Port _ | Token.Version _ | Token.Size _
  | Token.Ident _ | Token.Upper _ | Token.Hole
  | Token.LParen | Token.LBracket
  | Token.Dollar | Token.InterpStr _ | Token.RunCmdRaw _ | Token.RunQueryRaw _
  | Token.Regex _ | Token.EnvVar _
  | Token.Handle | Token.Try -> true
  | _ -> false

let is_expr_start = function
  | Token.Let | Token.If | Token.Match | Token.Fn
  | Token.Minus | Token.Bang -> true
  | t -> is_atom_start t

let is_pat_atom_start = function
  | Token.Int _ | Token.Float _ | Token.String _ | Token.Bool _
  | Token.Ident _ | Token.Underscore | Token.Upper _
  | Token.LParen | Token.LBracket -> true
  | _ -> false

(* ── Pattern parsing ──────────────────────────────────────────────────────── *)

let rec pat_ s =
  match peek s with
  | Token.Int n      -> ignore (advance s); (Int n : pat)
  | Token.Float f    -> ignore (advance s); Float f
  | Token.String str -> ignore (advance s); String str
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
      end else begin
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
        PConstr (name, !pats)
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
      end else (expect s Token.RParen; p)
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
        let tl = pat_ s in
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

let parse_type_expr s =
  let loc = loc_prefix s in
  match advance s with
  | Token.Upper name -> Ast.TEName name
  | Token.Ident name ->
    raise (ParseError (Printf.sprintf "%sexpected type name, got '%s'%s"
      loc name (Util.hint name builtin_types)))
  | t -> raise (ParseError (Format.asprintf "%sexpected type name, got %a" loc Token.pp t))

(* ── Expression parsing (Pratt) ───────────────────────────────────────────── *)

let rec expr_ bp s =
  let left = ref (atom_ s) in
  let continue_ = ref true in
  while !continue_ do
    let had_newline = has_newline_before_next s in
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

and atom_ s =
  let loc = loc_prefix s in
  match advance s with
  | Token.Int n      -> (Int n : expr)
  | Token.Float f    -> Float f
  | Token.String str -> String str
  | Token.Bool b     -> Bool b
  | Token.Path p     -> Path p
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
    if peek s = Token.Dot then begin
      (* Eagerly consume dot-chains so Ns.f is one atom *)
      let e = ref (Constr name) in
      while peek s = Token.Dot do
        ignore (advance s);
        e := Field (!e, expect_ident s)
      done;
      !e
    end else if peek_named_args s then begin
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
        List.fold_left (fun acc arg -> App (acc, arg)) (Constr name) !args
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
      let e = expr_ 0 s in
      if peek s = Token.Comma then begin
        let es = ref [e] in
        while peek s = Token.Comma do
          ignore (advance s); es := !es @ [expr_ 0 s]
        done;
        expect s Token.RParen; Tuple !es
      end else (expect s Token.RParen; e)
    end
  | Token.LBracket -> list_ s
  | Token.Let      -> let_ s
  | Token.If       -> if_ s
  | Token.Match    -> match_ s
  | Token.Fn       -> fn_ s
  | Token.Result   -> Var "result"
  | Token.Dollar   ->
    expect s Token.LParen;
    let e = expr_ 0 s in
    expect s Token.RParen;
    RunCmd e
  | Token.RunCmdRaw (parts, tail) ->
    let parse_parts = List.map (fun (lit, src) ->
      let toks = Lexer.tokenize src in
      let s2 = make toks in
      (lit, expr_ 0 s2)
    ) parts in
    if parse_parts = [] then RunCmd (String tail)
    else RunCmd (Interp (parse_parts, tail))
  | Token.RunQueryRaw (parts, tail) ->
    let parse_parts = List.map (fun (lit, src) ->
      let toks = Lexer.tokenize src in
      let s2 = make toks in
      (lit, expr_ 0 s2)
    ) parts in
    if parse_parts = [] then RunQuery (String tail)
    else RunQuery (Interp (parse_parts, tail))
  | Token.Regex (pat, flags) -> RegexLit (pat, flags)
  | Token.InterpStr (parts, tail) ->
    let parsed = List.map (fun (lit, src) ->
      let toks = Lexer.tokenize src in
      let s2 = make toks in
      (lit, expr_ 0 s2)
    ) parts in
    Interp (parsed, tail)
  | Token.Handle -> parse_handle_ s
  | Token.Try    -> Ast.Try (expr_ 0 s)
  | t -> raise (ParseError (Format.asprintf "%sunexpected token: %a%s"
      loc Token.pp t (keyword_hint t)))

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
  | PVar name when peek s <> Token.Eq ->
    (* function shorthand: let f params = body, with optional multi-equation *)
    let params = ref [] in
    while is_pat_atom_start (peek s) do
      params := !params @ [pat_atom_ s]
    done;
    let annot = if peek s = Token.Colon then
      (ignore (advance s); Some (parse_type_expr s))
    else None in
    expect s Token.Eq;
    let body_loc = peek_loc s in
    let body = Located (body_loc, parse_contract_body s) in
    if !params = [] then begin
      (* annotated value binding: let x : T = e *)
      let e = match annot with Some te -> Annot (te, body) | None -> body in
      let rest = consume_rest () in
      Let (PVar name, e, rest)
    end else begin
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
      let fn_val = match !eqs with
        | [(ps, b)] -> Fn (ps, b)
        | eqs ->
          let fresh = List.init arity (fun i -> Printf.sprintf "_p%d" i) in
          let scrutinee = match fresh with
            | [v] -> Var v
            | vs  -> Tuple (List.map (fun v -> Var v) vs)
          in
          let arms = List.map (fun (pats, b) ->
            let pat = match pats with [p] -> p | ps -> PTuple ps in
            (pat, None, b)
          ) eqs in
          Fn (List.map (fun v -> PVar v) fresh, Match (scrutinee, arms))
      in
      let rest = consume_rest () in
      Let (PVar name, fn_val, rest)
    end
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
  expect s Token.Else;
  let else_loc = peek_loc s in
  let else_ = Located (else_loc, expr_ 0 s) in
  If (cond, then_, else_)

and match_ s =
  (* match already consumed *)
  let scrutinee = expr_ 0 s in
  expect s Token.With;
  let arms = ref [] in
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
      arms := !arms @ [(p, guard, body)]
    end else
      continue_ := false
  done;
  Match (scrutinee, !arms)

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

(* ── Handle expression ────────────────────────────────────────────────────── *)

and parse_handle_ s =
  (* handle already consumed *)
  let body = expr_ 0 s in
  expect s Token.With;
  let arms = ref [] in
  let continue_ = ref true in
  while !continue_ do
    if peek s = Token.Pipe then begin
      ignore (advance s);
      let arm = match peek s with
        | Token.Return ->
          ignore (advance s);
          let p = pat_atom_ s in
          expect s Token.Arrow;
          let b_loc = peek_loc s in
          let b = Located (b_loc, expr_ 0 s) in
          Ast.ReturnArm (p, b)
        | Token.Ident op_name ->
          ignore (advance s);
          let arg_pat = pat_atom_ s in
          let cont_name = expect_ident s in
          expect s Token.Arrow;
          let b_loc = peek_loc s in
          let b = Located (b_loc, expr_ 0 s) in
          Ast.EffectArm (op_name, arg_pat, cont_name, b)
        | t ->
          raise (ParseError (Format.asprintf "%sunexpected token in handler arm: %a"
            (loc_prefix s) Token.pp t))
      in
      arms := !arms @ [arm]
    end else
      continue_ := false
  done;
  Ast.Handle (body, !arms)

let build_multi_equation name arity eqs =
  match eqs with
  | [(p, b)] -> Ast.TLLet (name, p, b)
  | eqs ->
    let fresh = List.init arity (fun i -> Printf.sprintf "_p%d" i) in
    let scrutinee = match fresh with
      | [v] -> Ast.Var v
      | vs  -> Ast.Tuple (List.map (fun v -> Ast.Var v) vs)
    in
    let arms = List.map (fun (pats, body) ->
      let pat = match pats with [p] -> p | ps -> Ast.PTuple ps in
      (pat, None, body)
    ) eqs in
    Ast.TLLet (name,
      List.map (fun v -> Ast.PVar v) fresh,
      Ast.Match (scrutinee, arms))

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
  let parse_ctor_fields () =
    (* Peek: if next is Upper, single positional field, no parens.
       If LParen, parse (fields...) where fields are either:
         - named:      ident Upper (, ident Upper)*
         - positional: Upper (, Upper)* *)
    match peek s with
    | Token.Upper _ ->
      [(None, parse_type_expr s)]
    | Token.LParen ->
      ignore (advance s);
      let named = match peek s with Token.Ident _ -> true | _ -> false in
      let parse_one () =
        if named then
          let fname = expect_ident s in
          let ftype = parse_type_expr s in
          (Some fname, ftype)
        else
          (None, parse_type_expr s)
      in
      let first = parse_one () in
      let rest = ref [] in
      while peek s = Token.Comma do
        ignore (advance s);
        rest := !rest @ [parse_one ()]
      done;
      expect s Token.RParen;
      first :: !rest
    | _ -> []
  in
  (* Single-constructor shorthand: type Foo (fields...) desugars to type Foo = Foo (fields...) *)
  if peek s = Token.LParen then begin
    let fields = parse_ctor_fields () in
    Ast.Variants (type_name, [{ Ast.name = type_name; fields }])
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
    Ast.Variants (type_name, !ctors)
  end

let parse_program tokens =
  let s = make tokens in
  let items = ref [] in
  let docs  = ref [] in
  let pending_doc : string option ref = ref None in
  let attach_doc name =
    match !pending_doc with
    | None -> ()
    | Some d -> docs := (name, d) :: !docs; pending_doc := None
  in
  let continue_ = ref true in
  while !continue_ do
    match peek s with
    | Token.EOF -> continue_ := false
    | Token.DocComment doc ->
      ignore (advance s);
      pending_doc := Some doc
    | Token.Newline | Token.Semicolon ->
      ignore (advance s)
    | Token.Let ->
      let saved = s.pos in
      ignore (advance s);
      (match peek s with
       | Token.Ident _ ->
         let name = expect_ident s in
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
               let ps = ref [] in
               while is_pat_atom_start (peek s) do ps := !ps @ [pat_atom_ s] done;
               if List.length !ps <> arity then raise Exit;
               (match peek s with Token.Eq -> ignore (advance s) | _ -> raise Exit);
               let b_loc = peek_loc s in
               let b = Ast.Located (b_loc, parse_contract_body s) in
               eqs := !eqs @ [(!ps, b)]
             with Exit -> s.pos <- saved2; more := false)
           done;
           items := !items @ [build_multi_equation name arity !eqs]
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
      (match tdef with Ast.Variants (name, _) -> attach_doc name);
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
      end
  done;
  { Ast.items = !items; docs = !docs }
