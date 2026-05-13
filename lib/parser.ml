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

let peek s =
  skip s;
  if s.pos < Array.length s.tokens then fst s.tokens.(s.pos) else Token.EOF

let peek_loc s =
  skip s;
  if s.pos < Array.length s.tokens
  then snd s.tokens.(s.pos)
  else Token.{ line = 0; col = 0 }

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
  | Token.Semicolon  -> 5
  | Token.PipeArrow -> 10
  | Token.PipePipe  -> 20
  | Token.AmpAmp    -> 30
  | Token.EqEq | Token.BangEq
  | Token.Lt   | Token.Gt
  | Token.LtEq | Token.GtEq -> 40
  | Token.Plus | Token.Minus | Token.PlusPlus -> 50
  | Token.Star | Token.Slash -> 60
  | Token.Dot  -> 80
  | _ -> 0

let is_atom_start = function
  | Token.Int _ | Token.Float _ | Token.String _ | Token.Bool _
  | Token.Path _ | Token.Date _ | Token.Time _ | Token.DateTime _
  | Token.Duration _ | Token.Url _ | Token.IPv4 _ | Token.CIDR _
  | Token.Port _ | Token.Version _ | Token.Size _
  | Token.Ident _ | Token.Upper _ | Token.Hole
  | Token.LParen | Token.LBracket | Token.LBrace
  | Token.Dollar | Token.InterpStr _ | Token.EnvVar _
  | Token.Handle -> true
  | _ -> false

let is_pat_atom_start = function
  | Token.Int _ | Token.Float _ | Token.String _ | Token.Bool _
  | Token.Ident _ | Token.Underscore | Token.Upper _
  | Token.LParen | Token.LBrace -> true
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
      end else (expect s Token.RParen; p)
    end
  | Token.LBrace ->
    ignore (advance s); record_pat_ s
  | Token.Upper name ->
    ignore (advance s);
    let args = ref [] in
    while is_pat_atom_start (peek s) do
      args := !args @ [pat_atom_ s]
    done;
    PConstr (name, !args)
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
  | Token.LBrace ->
    ignore (advance s); record_pat_ s
  | t ->
    let loc = loc_prefix s in
    raise (ParseError (Format.asprintf "%sunexpected token in pattern: %a%s"
      loc Token.pp t (keyword_hint t)))

and record_pat_ s =
  (* { already consumed *)
  let fields = ref [] in
  while peek s <> Token.RBrace do
    let key = expect_ident s in
    let p =
      if peek s = Token.Eq then (ignore (advance s); pat_ s)
      else PVar key
    in
    fields := !fields @ [(key, p)];
    if peek s = Token.Comma then ignore (advance s)
  done;
  expect s Token.RBrace;
  PRecord !fields

(* ── Expression parsing (Pratt) ───────────────────────────────────────────── *)

let rec expr_ bp s =
  let left = ref (atom_ s) in
  let continue_ = ref true in
  while !continue_ do
    let t = peek s in
    let bp' = lbp t in
    if bp' > bp then begin
      ignore (advance s);
      left := infix_ !left t s
    end else if is_atom_start t && 70 > bp && not s.in_contract then
      left := App (!left, atom_ s)
    else
      continue_ := false
  done;
  !left

and infix_ left op s =
  match op with
  | Token.Semicolon  -> Seq (left, expr_ 4 s)
  | Token.PipeArrow -> BinOp ("|>", left, expr_ 10 s)
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
  | Token.Star      -> BinOp ("*",  left, expr_ 60 s)
  | Token.Slash     -> BinOp ("/",  left, expr_ 60 s)
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
  | Token.Upper name  -> Constr name
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
  | Token.LBrace   -> record_ s
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
  | Token.InterpStr (parts, tail) ->
    let parsed = List.map (fun (lit, src) ->
      let toks = Lexer.tokenize src in
      let s2 = make toks in
      (lit, expr_ 0 s2)
    ) parts in
    Interp (parsed, tail)
  | Token.Handle -> parse_handle_ s
  | t -> raise (ParseError (Format.asprintf "%sunexpected token: %a%s"
      loc Token.pp t (keyword_hint t)))

and list_ s =
  (* [ already consumed *)
  if peek s = Token.RBracket then (ignore (advance s); List [])
  else begin
    let elems = ref [expr_ 0 s] in
    while peek s = Token.Comma do
      ignore (advance s); elems := !elems @ [expr_ 0 s]
    done;
    expect s Token.RBracket;
    List !elems
  end

and record_ s =
  (* { already consumed *)
  let fields = ref [] in
  while peek s <> Token.RBrace do
    let key = expect_ident s in
    expect s Token.Eq;
    let v = expr_ 0 s in
    fields := !fields @ [(key, v)];
    if peek s = Token.Comma then ignore (advance s)
  done;
  expect s Token.RBrace;
  Record !fields

and let_ s =
  (* let already consumed *)
  let p = pat_ s in
  match p with
  | PVar name when peek s <> Token.Eq ->
    (* function shorthand: let f params = body in rest *)
    let params = ref [] in
    while is_pat_atom_start (peek s) do
      params := !params @ [pat_atom_ s]
    done;
    expect s Token.Eq;
    let body = parse_contract_body s in
    expect s Token.In;
    let rest = expr_ 0 s in
    Let (PVar name, Fn (!params, body), rest)
  | _ ->
    expect s Token.Eq;
    let e1 = expr_ 0 s in
    expect s Token.In;
    let e2 = expr_ 0 s in
    Let (p, e1, e2)

and if_ s =
  (* if already consumed *)
  let cond  = expr_ 0 s in
  expect s Token.Then;
  let then_ = expr_ 0 s in
  expect s Token.Else;
  let else_ = expr_ 0 s in
  If (cond, then_, else_)

and match_ s =
  (* match already consumed *)
  let scrutinee = expr_ 0 s in
  expect s Token.With;
  let arms = ref [] in
  while peek s = Token.Pipe do
    ignore (advance s);
    let p = pat_ s in
    let guard =
      if peek s = Token.When
      then (ignore (advance s); Some (expr_ 0 s))
      else None
    in
    expect s Token.Arrow;
    let body = expr_ 0 s in
    arms := !arms @ [(p, guard, body)]
  done;
  Match (scrutinee, !arms)

and contract_expr_ s =
  let saved = s.in_contract in
  s.in_contract <- true;
  let e = expr_ 0 s in
  s.in_contract <- saved;
  e

and parse_contract_body s =
  let reqs = ref [] in
  let ens  = ref [] in
  let continue_ = ref true in
  while !continue_ do
    match peek s with
    | Token.Requires -> ignore (advance s); reqs := !reqs @ [contract_expr_ s]
    | Token.Ensures  -> ignore (advance s); ens  := !ens  @ [contract_expr_ s]
    | _ -> continue_ := false
  done;
  let body = expr_ 0 s in
  if !reqs = [] && !ens = [] then body
  else Ast.Contract (!reqs, !ens, body)

and fn_ s =
  (* fn already consumed *)
  let params = ref [] in
  while is_pat_atom_start (peek s) do
    params := !params @ [pat_atom_ s]
  done;
  expect s Token.Arrow;
  Fn (!params, parse_contract_body s)

(* ── Handle expression ────────────────────────────────────────────────────── *)

and parse_handle_ s =
  (* handle already consumed *)
  let body = expr_ 0 s in
  expect s Token.With;
  let arms = ref [] in
  while peek s = Token.Pipe do
    ignore (advance s);
    let arm = match peek s with
      | Token.Return ->
        ignore (advance s);
        let p = pat_atom_ s in
        expect s Token.Arrow;
        let b = expr_ 0 s in
        Ast.ReturnArm (p, b)
      | Token.Ident op_name ->
        ignore (advance s);
        let arg_pat = pat_atom_ s in
        let cont_name = expect_ident s in
        expect s Token.Arrow;
        let b = expr_ 0 s in
        Ast.EffectArm (op_name, arg_pat, cont_name, b)
      | t ->
        raise (ParseError (Format.asprintf "%sunexpected token in handler arm: %a"
          (loc_prefix s) Token.pp t))
    in
    arms := !arms @ [arm]
  done;
  Ast.Handle (body, !arms)

(* ── Multi-equation merging ───────────────────────────────────────────────── *)

(* Merge consecutive top-level lets with the same name and arity into one
   function whose body dispatches via match. *)
let merge_equations items =
  let rec go acc = function
    | [] -> List.rev acc
    | Ast.TLLet (name, (_ :: _ as params), body) :: rest ->
      let arity = List.length params in
      let eqs  = ref [(params, body)] in
      let tail = ref rest in
      let stop = ref false in
      while not !stop do
        match !tail with
        | Ast.TLLet (n2, p2, b2) :: rest2
          when n2 = name && List.length p2 = arity ->
          eqs  := !eqs @ [(p2, b2)];
          tail := rest2
        | _ -> stop := true
      done;
      let item = match !eqs with
        | [(p, b)] -> Ast.TLLet (name, p, b)
        | eqs ->
          let fresh = List.init arity (fun i -> Printf.sprintf "_p%d" i) in
          let scrutinee = match fresh with
            | [v] -> Ast.Var v
            | vs  -> Ast.Tuple (List.map (fun v -> Ast.Var v) vs)
          in
          let arms = List.map (fun (pats, body) ->
            let pat = match pats with
              | [p] -> p
              | ps  -> Ast.PTuple ps
            in
            (pat, None, body)
          ) eqs in
          Ast.TLLet (name,
            List.map (fun v -> Ast.PVar v) fresh,
            Ast.Match (scrutinee, arms))
      in
      go (item :: acc) !tail
    | item :: rest -> go (item :: acc) rest
  in
  go [] items

(* ── Public API ───────────────────────────────────────────────────────────── *)

let parse_expr tokens =
  let s = make tokens in
  expr_ 0 s

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

let parse_type_fields s =
  let first = parse_type_expr s in
  let rest = ref [] in
  while peek s = Token.Star do
    ignore (advance s);
    rest := !rest @ [parse_type_expr s]
  done;
  first :: !rest

let parse_type_def s =
  (* type already consumed *)
  let type_name =
    let loc = loc_prefix s in
    match advance s with
    | Token.Upper n -> n
    | t -> raise (ParseError (Format.asprintf "%sexpected type name, got %a" loc Token.pp t))
  in
  expect s Token.Eq;
  match peek s with
  | Token.LBrace ->
    ignore (advance s);
    let fields = ref [] in
    while peek s <> Token.RBrace do
      let fname = expect_ident s in
      expect s Token.Colon;
      let ftype = parse_type_expr s in
      fields := !fields @ [(fname, ftype)];
      if peek s = Token.Comma then ignore (advance s)
    done;
    expect s Token.RBrace;
    Ast.RecordType (type_name, !fields)
  | _ ->
    let ctors = ref [] in
    let parse_ctor () =
      let name =
        let loc = loc_prefix s in
        match advance s with
        | Token.Upper n -> n
        | t -> raise (ParseError (Format.asprintf "%sexpected constructor name, got %a" loc Token.pp t))
      in
      let fields =
        if peek s = Token.Of then (ignore (advance s); parse_type_fields s)
        else []
      in
      { Ast.name; fields }
    in
    ctors := [parse_ctor ()];
    while peek s = Token.Pipe do
      ignore (advance s);
      ctors := !ctors @ [parse_ctor ()]
    done;
    Ast.Variants (type_name, !ctors)

let parse_program tokens =
  let s = make tokens in
  let items = ref [] in
  let start = ref None in
  let continue_ = ref true in
  while !continue_ do
    match peek s with
    | Token.EOF -> continue_ := false
    | Token.Let ->
      ignore (advance s);
      let name = expect_ident s in
      let params = ref [] in
      while is_pat_atom_start (peek s) do
        params := !params @ [pat_atom_ s]
      done;
      expect s Token.Eq;
      let loc = peek_loc s in
      let body = Ast.Located (loc, parse_contract_body s) in
      items := !items @ [Ast.TLLet (name, !params, body)]
    | Token.Import ->
      ignore (advance s);
      (match advance s with
       | Token.String path -> items := !items @ [Ast.TLImport path]
       | t -> raise (ParseError (Format.asprintf "expected string after import, got %a" Token.pp t)))
    | Token.Start ->
      ignore (advance s);
      let loc = peek_loc s in
      start := Some (Ast.Located (loc, expr_ 0 s))
    | Token.Type ->
      ignore (advance s);
      items := !items @ [Ast.TLType (parse_type_def s)]
    | t ->
      let loc = loc_prefix s in
      raise (ParseError (Format.asprintf "%sunexpected top-level token: %a%s"
        loc Token.pp t (keyword_hint t)))
  done;
  { Ast.items = merge_equations !items; Ast.start = !start }
