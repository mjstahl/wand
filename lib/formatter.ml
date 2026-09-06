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
let max_width = ref 92

type comment_tok = {
  c_offset : int; c_start_line : int; c_end_line : int; c_text : string;
  (* Whether the comment begins its line. One that follows code on the same
     line annotates that code, so it cannot be lifted onto a line of its own
     without changing what it points at. *)
  c_own_line : bool;
}

(* Trailing whitespace, off a comment's text before anything sees it.

   It is never meaningful there -- a comment runs to the end of its line, so
   the spaces before that end say nothing -- and carrying it made the
   formatter write a line ending in `-- `. The next pass lexed that comment
   without the space and wrote `--`, so the file changed on the second pass
   and went on changing between the two spellings. Four seeds found it the
   same night.

   Only the trailing end. The space *after* the dashes is style the
   formatter must not touch. *)
let rstrip_ws raw =
  let len = String.length raw in
  let j = ref len in
  while !j > 0 && (raw.[!j - 1] = ' ' || raw.[!j - 1] = '\t'
                   || raw.[!j - 1] = '\n' || raw.[!j - 1] = '\r') do decr j done;
  String.sub raw 0 !j

let starts_its_line src off =
  let rec back i = i < 0 || (match src.[i] with
    | '\n' -> true
    | ' ' | '\t' | '\r' -> back (i - 1)
    | _ -> false)
  in back (off - 1)

let all_comments src tokens : comment_tok list =
  List.filter_map (fun (tok, (loc : Token.loc)) ->
    match tok with
    | Token.LineComment text ->
      (* A comment is always exactly one line. *)
      Some { c_offset = loc.offset; c_start_line = loc.line;
             c_end_line = loc.line; c_text = rstrip_ws ("--" ^ text);
             c_own_line = starts_its_line src loc.offset }
    | _ -> None
  ) tokens

(* ── Comments inside an item ──────────────────────────────────────────────── *)

(* A comment between two top-level items is a piece of its own, laid out by
   `assemble`. One *inside* an item has to be written by whichever emitter
   reaches the boundary it sits at, because pretty-printing rebuilds those
   lines from the AST and the AST does not carry it.

   `interior` holds the comments inside the item being printed. Reading it
   is a lookup, never a removal: the emitters render candidate layouts and
   throw most of them away -- a `match` is rendered to find out whether it
   fits before it is rendered to be kept -- and a comment consumed by a
   draft would vanish with it.

   So an emitter asks for the comments between where the construct before it
   ended and where this one starts. A comment *within* the previous
   construct falls outside that window and is left for the emitter that
   descends into it. *)
let interior : comment_tok list ref = ref []

(* Where the item being printed starts. A comment at the very top of a
   definition's body has nothing before it to open a window against; the
   item's own start is the bound, since `interior` holds only what is
   inside this item. *)
let item_start = ref 0

(* Only a comment on a line of its own can be written above a construct. A
   trailing one stays unplaced, which sends its item to a verbatim slice
   rather than moving the note off the code it is about. *)
let comments_between lo hi =
  List.filter (fun c -> c.c_own_line && c.c_offset > lo && c.c_offset < hi) !interior

let loc_of = function Located (l, _) -> Some l | _ -> None

(* Run `f` against a different column budget and put the old one back. Only
   the tests narrow it: formatting the corpus at a margin nothing fits under
   is how the "emitted source that will not parse" bugs are found, and every
   one of them so far needed a line long enough to wrap before it showed.
   Narrowing the margin makes every line long enough. *)
let with_width w f =
  let saved = !max_width in
  max_width := w;
  Fun.protect ~finally:(fun () -> max_width := saved) f

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
  not (String.contains s '\n') && col + String.length s <= !max_width

(* The keyword a binding opens with, and the column its name starts at. A
   binding's later clauses line up under the first one's name rather than at
   a fixed step, so a sibling keyword -- `letrec` -- would carry its own
   clauses across without a second number to keep in step. *)
let let_keyword = "let"

let name_column indent keyword = indent + String.length keyword + 1

let strip_located = Ast.strip_located

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
  (* `{` or `!{` at this position -- the two shapes an opener takes. *)
  let opens_at j =
    j < n && (str.[j] = '{'
              || (str.[j] = '!' && j + 1 < n && str.[j + 1] = '{'))
  in
  String.iteri (fun i c ->
    match c with
    | '\\' -> Buffer.add_string buf "\\\\"
    | '"'  -> Buffer.add_string buf "\\\""
    | '\n' -> Buffer.add_string buf "\\n"
    | '\t' -> Buffer.add_string buf "\\t"
    | '\r' -> Buffer.add_string buf "\\r"
    (* Every opener the lexer reacts to inside a string has to come back
       escaped or the text will not read as itself: `%{` interpolates, and
       `%!{`, `${`, `$!{` and `#{` are all refused, each as the wrong
       spelling of one. Escaping only the first two meant `wand f` could
       write a file it could no longer read. *)
    | ('$' | '%') when opens_at (i + 1) ->
      Buffer.add_char buf '\\'; Buffer.add_char buf c
    | '#' when i + 1 < n && str.[i + 1] = '{' -> Buffer.add_string buf "\\#"
    | c -> Buffer.add_char buf c
  ) str;
  Buffer.contents buf

let contains_sub s sub =
  let n = String.length s and m = String.length sub in
  let rec go i = i + m <= n && (String.sub s i m = sub || go (i + 1)) in
  go 0

(* Text that would come back full of backslash-escaped quotes reads better
   between backticks, where a quote is a quote. Only when the raw form
   reproduces the value exactly and visibly: no backtick (there is no way
   to write one), no `%{` (it would interpolate), and no control
   characters -- turning a spelled-out `\n` or `\t` into invisible layout
   is a worse trade than the escaped quotes. *)
let raw_safe s =
  not (String.contains s '`')
  && not (contains_sub s "%{")
  && String.for_all (fun c -> c <> '\n' && c <> '\t' && c <> '\r') s

let prefers_raw s = String.contains s '"' && raw_safe s

(* `%g` drops a trailing `.0` for integral floats (`42.0` -> `"42"`), which
   then re-lexes as an Int literal, not a Float -- silently changing the
   program. Force the printed form to always look like a float. *)
(* The shortest plain-decimal spelling that reads back as the same value.

   `%g` was none of those things. It carries six significant digits and
   switches to an exponent past them, so `2222222.5` came back as
   `2.22222e+06` -- a different number, in a spelling wand has no lexer for:
   there is no exponent form, so that re-read as four tokens, `2.22222`,
   `e`, `+` and `6`. Found by test/fuzz.

   Precision rises until the string reads back equal, so the answer is exact
   and no longer than it has to be. It starts at one digit, which is what
   keeps the `.` that tells a Float from an Int. Every float printed here
   was a literal someone wrote, and wand has no way to write one that needs
   an exponent, so the cap is only a backstop. *)
let string_of_wand_float f =
  match classify_float f with
  | FP_nan -> "nan"
  (* A literal too large for a double lexes to infinity, and `inf` is not a
     way to write that back: the word re-reads as a variable, which is how a
     file that typechecked came back as an unbound name. The only notation
     wand has for it is the one the input used -- enough digits to overflow
     -- so that is what goes back. `1` and 309 zeros is the first power of
     ten past the largest finite double. Found by test/fuzz. *)
  | FP_infinite ->
    let overflowing = "1" ^ String.make 309 '0' ^ ".0" in
    if f > 0.0 then overflowing else "-" ^ overflowing
  | _ ->
    let rec go p =
      if p > 24 then Printf.sprintf "%.24f" f
      else
        let s = Printf.sprintf "%.*f" p f in
        if float_of_string s = f then s else go (p + 1)
    in
    go 1

(* ── Verbatim fallback ─────────────────────────────────────────────────────
   An item whose interior holds a comment is re-emitted as an exact source
   slice. Formatting it would mean deciding where the comment now belongs,
   and a comment moved to the wrong expression is worse than one left where
   its author put it.

   Nothing else falls back: contracts, `handle`, `$()`/`$?()`, `try` and
   regex literals each have a formatting rule. *)

(* ── Type expressions ────────────────────────────────────────────────────── *)

(* `! {Shell, IO}`, `! 'e`, `! {Shell | 'e}` -- written back exactly as the
   author wrote it and as the printer emits it, so a formatted signature is
   still one the grammar reads. *)
let emit_te_effects = function
  | None -> ""
  | Some { te_labels = []; te_var = None } -> " ! {}"
  | Some { te_labels = []; te_var = Some v } -> " ! '" ^ v
  | Some { te_labels; te_var } ->
    let names = String.concat ", " te_labels in
    (match te_var with
     | None   -> " ! {" ^ names ^ "}"
     | Some v -> " ! {" ^ names ^ " | '" ^ v ^ "}")

let rec emit_type_expr te = match te with
  | TEFun (a, b, eff) ->
    emit_type_operand a ^ " -> " ^ emit_type_expr b ^ emit_te_effects eff
  | _ -> emit_type_app_expr te
and emit_type_operand te = match te with
  | TEFun _ -> "(" ^ emit_type_expr te ^ ")"
  | _ -> emit_type_expr te
and emit_type_app_expr te = match te with
  | TEApp (f, a) -> emit_type_app_expr f ^ " " ^ emit_type_atom a
  | _ -> emit_type_atom te
and emit_type_atom te = match te with
  | TEName n -> n
  | TEQual (m, n) -> m ^ "." ^ n
  | TEVar v -> "'" ^ v
  | TETuple ts -> "(" ^ String.concat ", " (List.map emit_type_expr ts) ^ ")"
  | TEApp _ | TEFun _ -> "(" ^ emit_type_expr te ^ ")"

(* ── Patterns ─────────────────────────────────────────────────────────────── *)

(* A map key is written bare when it is an identifier and quoted when it is
   not. `Map` keys are arbitrary strings -- `"content-type"`, `"@type"` -- and
   the parser takes them quoted; printing one of those bare produces source
   that does not lex at all. Quoting is always correct, so the bare form is
   only an economy for the keys that can afford it. *)
(* A key written bare, where the parser that will read it back allows one.
   The two parsers differ. A destructured import names types and
   constructors -- `let {TestOutcome, Pass} = import Test` -- and the
   pattern parser reads those bare. The expression parser does not:
   `{Pod = 1}` stops at the constructor, so a map literal's uppercase key
   keeps its quotes. One function served both and wrote `{"Pod" = 1}` back
   as source that does not parse. Found by the nightly fuzz run, standing
   behind the keyword bug in the same function. *)
let map_key ?(upper_is_bare = false) k =
  (* One trailing ? or ! is part of an identifier (predicate / bang
     convention), matching the lexer's rule exactly -- `deploy!` is a key
     that can afford the bare form. *)
  let n = String.length k in
  let core =
    if n > 1 && (k.[n - 1] = '?' || k.[n - 1] = '!')
    then String.sub k 0 (n - 1) else k
  in
  let plain =
    String.length core > 0
    && (match core.[0] with
        | 'a' .. 'z' | '_' -> true
        | 'A' .. 'Z' -> upper_is_bare
        | _ -> false)
    && String.for_all (function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true | _ -> false) core
    (* Spelled like an identifier is not the same as read as one. `type`,
       `let`, `true` and the rest lex as keywords wherever they appear, so
       `{"type" = 1}` unquoted is `{type = 1}`, which stops at the keyword.
       The lexer is asked rather than a second list kept here: a list that
       has to be updated with the language is a list that will not be.
       Found by the nightly fuzz run. *)
    && (match Lexer.keyword_or_ident core with
        | Token.Ident _ | Token.Upper _ -> true
        | _ -> false)
  in
  if plain then k else "\"" ^ escape_string_body k ^ "\""

let rec emit_pat (p : pat) : string = match p with
  | Int n      -> string_of_int n
  | Float f    -> string_of_wand_float f
  | String s   -> "\"" ^ escape_string_body s ^ "\""
  | Bool b     -> string_of_bool b
  | Unit       -> "()"
  | Path s | DateTime s | Duration s
  | URL s | CIDR s | Version s | Size s | IPv4 s -> s
  | Port n     -> ":" ^ string_of_int n
  | PVar x     -> x
  | Wild       -> "_"
  | PTuple ps  -> "(" ^ String.concat ", " (List.map emit_pat ps) ^ ")"
  | PList ps   -> "[" ^ String.concat ", " (List.map emit_pat ps) ^ "]"
  | PCons (h, t) -> emit_cons_chain h t
  | PConstr (c, []) -> c
  (* A parenthesised list of arguments is printed against the constructor,
     with no space, as a field list is. The declaration tells the two apart,
     not the spelling. `Pod(name, restarts)` is a field list where `Pod`
     names its fields, and a tuple payload where it does not. Both are
     printed alike, so the space cannot look like the thing that decides. *)
  | PConstr (c, [PTuple (_ :: _ :: _ as ps)]) ->
    c ^ "(" ^ String.concat ", " (List.map emit_pat ps) ^ ")"
  | PConstr (c, ps) -> c ^ " " ^ String.concat " " (List.map emit_pat_atom ps)
  | PConstrNamed (c, kvs) ->
    (* Punned whenever the field already names its variable, the same rule a
       map pattern is printed under -- except where the pun would be the
       only thing inside the parentheses. `M(a)` is the payload under that
       name, not the field `a`: one identifier is the one shape the
       declaration does not get to settle, so `M(a = a)` written that way
       came back as a pattern of another kind and stopped typechecking. A
       pun beside anything else is safe, because the `=` on its neighbour is
       what says these are fields. *)
    let entry (k, p) =
      match p with PVar v when v = k -> k | _ -> k ^ " = " ^ emit_pat p
    in
    let entries =
      match kvs with
      | [(k, PVar v)] when v = k -> [k ^ " = " ^ k]
      | _ -> List.map entry kvs
    in
    c ^ "(" ^ String.concat ", " entries ^ ")"
  | PConstrBare (c, ids) -> c ^ "(" ^ String.concat ", " ids ^ ")"
  | PQualified (m, p) -> m ^ "." ^ emit_pat p
  | PMap kvs ->
    (* Punned whenever the key already names its variable; a quoted key has
       no identifier to pun into, so it always carries its pattern. *)
    let entry (k, p) =
      match p with
      | PVar v when v = k && map_key ~upper_is_bare:true k = k -> k
      | _ -> map_key ~upper_is_bare:true k ^ " = " ^ emit_pat p
    in
    "{" ^ String.concat ", " (List.map entry kvs) ^ "}"
  (* The parentheses are the syntax, not decoration: `p : Pod` on its own
     is a cons expression. *)
  | PAnnot (p, te) -> "(" ^ emit_pat p ^ ": " ^ emit_type_expr te ^ ")"

(* A parameter. `PQualified` belongs here for the same reason it belongs in
   `emit_pat_binder`: a parameter list is read as names until the `->` or the
   `=`, so a `.` inside one stops the parse. `let a (t.A) = c` came back as
   `let a t.A = c` and `fn (e.T) -> s` as `fn e.T -> s`, neither of which
   parses. Unlike the binder case this holds in every position, because a
   parameter is never the head of anything. Found by test/fuzz. *)
and emit_pat_atom (p : pat) : string = match p with
  | PConstr (_, _ :: _) | PConstrNamed _ | PConstrBare _ | PQualified _ ->
    "(" ^ emit_pat p ^ ")"
  | _ -> emit_pat p

(* The pattern a *top-level* `let` binds. At the top of a file the head of a
   `let` is read as the name being defined, so a pattern that does not begin
   as a plain name has to arrive inside brackets or the parse stops partway
   through it: `let e.I =` stops at the dot and `let P(a = 1) =` stops at
   the `=` between the parentheses. Three more change meaning instead of
   failing -- `let Some x = e` is read back as a one-clause definition of a
   function named `Some`, `let E = e` as a value named `E` rather than a
   match against the constructor, and `let P(a, b) = e` loses the bracket
   that says the identifiers are the payload.

   Only at the top level. A `let ... in` and a block binding parse their
   head as a pattern already, so the same brackets there are noise -- they
   rewrote four lines of test/wand/test_typedef.wand, which is what said so.
   A tuple, a list and a map carry brackets of their own in either position
   and take no second pair. Found by test/fuzz, under three signatures. *)
and emit_pat_binder (p : pat) : string = match p with
  | PQualified _ | PConstrNamed _ | PConstrBare _ | PConstr _ ->
    "(" ^ emit_pat p ^ ")"
  | _ -> emit_pat p

and emit_cons_chain (h : pat) (t : pat) : string =
  let rec collect acc (p : pat) : pat list * pat = match p with
    | PCons (h2, t2) -> collect (h2 :: acc) t2
    | _ -> (List.rev acc, p)
  in
  let (elems, tail) = collect [h] t in
  "[" ^ String.concat " :: " (List.map emit_pat elems) ^ " :: " ^ emit_pat tail ^ "]"

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
  | "|>" -> 10 | "::" -> 15 | "||" -> 20 | "&&" -> 30
  | "==" | "!=" | "<" | ">" | "<=" | ">=" -> 40
  | "+" | "-" | "++" -> 50
  | "*" | "/" | "%" -> 60
  | _ -> 0

let bin_right_assoc = function "::" -> true | _ -> false

let is_control_expr e = match strip_located e with
  | Let _ | LetRec _ | If _ | Match _ | Fn _ | Handle _ | Try _ | Contract _
  | With _ -> true
  | _ -> false

let is_binop_or_unop e = match strip_located e with
  | BinOp _ | UnOp _ -> true
  | _ -> false

(* A value that carries its own opening bracket: `(`, `[`, `{`, or the
   parenthesis of a statement sequence. When one of these is what a binding
   binds, the bracket opens on the binding's line and the items carry the
   break. Given a line of its own the bracket says nothing -- the items sit
   at the same column either way -- while costing a line at the top of
   every list, map, and tuple wide enough to wrap.

   A block writes its parenthesis in `emit_block`, which reaches it by three
   shapes, not one: a bare sequence, and a sequence whose first statement is
   a binding. All three belong here, or a block that opens with a `let`
   spends the line the other two are spared. *)
(* A backtick string that spans lines. The lines under its opening backtick
   are the string's own content, laid out by whoever wrote it -- the one
   text in a wand file the formatter must not touch, and the one it cannot
   move without moving what the program says. *)
let is_multiline_raw_string e = match strip_located e with
  | RawString s -> String.contains s '\n'
  | RawInterp (parts, tail) ->
    List.exists (fun (chunk, _) -> String.contains chunk '\n') parts
    || String.contains tail '\n'
  | _ -> false

let opens_a_bracket e = match strip_located e with
  | Seq _ | List _ | Tuple _ | MapLit _ -> true
  | Let (_, _, _, LetBlock) | LetRec (_, _, LetBlock) -> true
  (* One of these opens a bracket in the sense that matters here: the
     opening backtick leaves its line as unfinished as a bare `[` does, and
     the text carries the break. Given a line of its own it says nothing,
     and it pushes the author's layout down the page to say it. *)
  | e' -> is_multiline_raw_string e'


(* Where a bracket carries the break, the value can start on the line that
   introduces it rather than taking a line of its own. That is a bracket of
   the value's own, and also a call whose last argument is one: `emit_app`
   opens that bracket on the call's line, so `report [` leaves the first
   line as unfinished as a bare `[` does. An `App` is left-nested, so the
   argument beside the outermost one is the last. *)
(* Where text leaves the cursor. A prefix that wrapped carries its own
   indentation in its last line, so that line's length is the column
   outright; one that did not starts wherever the caller said. *)
let column_after col s =
  match String.rindex_opt s '\n' with
  | None -> col + String.length s
  | Some i -> String.length s - i - 1

(* `fn a b ->`, and `fn ->` when it binds nothing. Joining an empty
   parameter list with spaces on both sides wrote `fn  ->`. *)
let emit_fn_head ps =
  match ps with
  | [] -> "fn ->"
  | _ -> "fn " ^ String.concat " " (List.map emit_pat_atom ps) ^ " ->"

let carries_the_break e =
  opens_a_bracket e
  || (match strip_located e with
      | App (_, last) -> opens_a_bracket last
      | _ -> false)

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
(* The parser continues a definition onto the next line only while a bracket
   is still open -- `test "x" (fn t ->` ends inside one, so what follows
   belongs to it. A line that closes everything it opened ends the
   definition, and the lines after it become something else. So this counts
   the brackets left open at the end of the first line -- the same three
   pairs the parser counts for the same purpose. *)
let depth_after_first_line str =
  let n = String.length str in
  let rec go i depth in_string =
    if i >= n then depth
    else
      match str.[i] with
      | '\n' when not in_string -> depth
      | '\\' when in_string -> go (i + 2) depth in_string
      | '"' -> go (i + 1) depth (not in_string)
      | ('(' | '[' | '{') when not in_string -> go (i + 1) (depth + 1) in_string
      | (')' | ']' | '}') when not in_string -> go (i + 1) (depth - 1) in_string
      | _ -> go (i + 1) depth in_string
  in
  go 0 0 false

(* Every line end the parser is free to stop at. `depth_after_first_line`
   asks about the first line alone, which was enough while a wrapped
   application put its argument straight below a callee that fit on one
   line. It is not enough when the callee itself spans lines: a block
   argument opens a bracket on the first line and closes it three lines
   down, and the argument written below *that* is where the definition
   quietly ends. So this looks for any line end that closes everything it
   opened and still has text after it -- every point the parse can be called
   finished, not just the first. Found by test/fuzz. *)
let breaks_at_depth_zero str =
  let n = String.length str in
  let rec blank_from i =
    i >= n
    || (match str.[i] with ' ' | '\t' | '\n' -> blank_from (i + 1) | _ -> false)
  in
  let rec go i depth in_string =
    if i >= n then false
    else
      match str.[i] with
      | '\n' when not in_string ->
        (depth <= 0 && not (blank_from (i + 1))) || go (i + 1) depth in_string
      | '\\' when in_string -> go (i + 2) depth in_string
      | '"' -> go (i + 1) depth (not in_string)
      | ('(' | '[' | '{') when not in_string -> go (i + 1) (depth + 1) in_string
      | (')' | ']' | '}') when not in_string -> go (i + 1) (depth - 1) in_string
      | _ -> go (i + 1) depth in_string
  in
  go 0 0 false

(* Does wrapping this finish it? An application does end where its line
   does, so what follows is read as something new. `try` is transparent
   here: it prefixes a keyword and changes nothing about whether the tail is
   still owed something, so `try f a b` is as unsafe as `f a b` and
   `try with r as p -> ...` is as safe as the `with` -- which is still owed
   its body when the first line ends.

   Everything else is safe: an `if` is owed a `then`, a `match` and a
   `handle` are owed cases, a `fn` is owed a body. The parse is unfinished
   at the first line, so the lines below it can only belong to it.

   `Try` was missing here, which is how `match try f a b ... with` came to
   be formatted into source that does not parse. Found by test/fuzz. *)
let rec wrapping_ends_it e =
  match strip_located e with
  | App _ -> true
  | Try inner -> wrapping_ends_it inner
  | _ -> false

(* Whether the last thing this expression writes is a `match` or `handle`
   arm. A `;` after one of those lands hard against the arm -- `| Error _ ->
   0;` reads as part of the arm, and the reader has to know the `;` closed
   the statement above it. The parse is not in doubt: the arms are still owed
   when the `;` arrives. Only the reading is, so the bracket goes on the
   whole construct and the `;` follows a `)` like every other statement's. *)
let rec ends_in_an_arm e =
  match strip_located e with
  | Match _ | Handle _ -> true
  | Fn (_, body) -> ends_in_an_arm body
  | If (_, _, els) -> ends_in_an_arm els
  | Let (_, _, body, _) | LetRec (_, body, _) -> ends_in_an_arm body
  | With (_, _, body) -> ends_in_an_arm body
  | Annot (_, inner) -> ends_in_an_arm inner
  | Seq (_, b) -> ends_in_an_arm b
  | _ -> false

(* An opening bracket, kept off a star.

   A glob literal opens with one, and a bracket written straight onto it
   makes the two characters the lexer reads as an attempt at a block comment
   -- it reports that, having no idea a bracket was meant. Every place that
   writes a bracket in front of emitted text goes through here, because the
   hazard belongs to the bracket rather than to any one of them: it was fixed
   in `parenthesize` first, then turned up again from a case body, and again
   from a tuple, a `;` block and a record update, none of which wrap anything
   -- they open a bracket and put the first item after it, which is the same
   two characters. Found by test/fuzz, three times.

   `(` only: `[*` and `{*` are not the comment opener and need no space, and
   a space written where none is needed is a diff nobody meant. *)
let opener o s = if o = "(" && s <> "" && s.[0] = '*' then "( " else o

let bracket s = opener "(" s ^ s ^ ")"

(* Which atoms take a following bracket as their own. `constr_body_` reads
   one straight after a constructor name, qualified or not, and nothing else
   on an application spine does it. *)
let rec absorbs_a_bracket e =
  match strip_located e with
  | Constr _ -> true
  | Qualified (_, inner) -> absorbs_a_bracket inner
  | _ -> false

(* Whether the bracket an argument opens with holds the whole of it, and
   holds something. A constructor takes the bracket written after it either
   way, and that is harmless exactly when the two are the same text: `S (x)`
   and `S x` build one node. Two renderings are not that. `()` is the empty
   field list rather than unit in brackets, so `O ()` comes back as the
   constructor with no payload where `O (())` keeps the argument. And a
   bracket that closes before the end leaves what follows it outside the
   payload: `O (d).n` reads as `(O d).n`, a different program, and one that
   still typechecks. Found by test/fuzz, under three signatures. *)
let bracket_holds_all s =
  (* Asked of the tokens, not of the characters. A hand-rolled scan has to
     know every form that can hold a bracket or a quote without meaning one,
     and it knew about `"` alone: a `"` inside a command opened a string that
     never closed, and a `)` inside one closed the bracket early. Either way
     the answer came back "no" for a bracket that does hold everything, and
     the constructor before it took a bracket it did not need -- harmless as
     `(O) (e `)`)`, and unparseable as `t.(O) (e `)`)`, which is what a
     qualified name makes of it. The lexer already knows the forms. Found by
     test/fuzz.

     A rendering that does not lex is not one this can answer for, so it
     answers no, which is the side that only ever adds a bracket. *)
  match Lexer.tokenize s with
  | exception _ -> false
  | (Token.LParen, _) :: rest ->
    let rec go depth = function
      | [] | [(Token.EOF, _)] -> false
      | (t, _) :: tl ->
        (match t with
         | Token.LParen | Token.LBracket | Token.LBrace -> go (depth + 1) tl
         | Token.RParen | Token.RBracket | Token.RBrace ->
           if depth > 0 then go (depth - 1) tl
           (* The opener closes here. It holds everything exactly when
              nothing but the end of the string follows. *)
           else (match tl with [] | [(Token.EOF, _)] -> true | _ -> false)
         | _ -> go depth tl)
    in
    (* `()` is the empty field list rather than unit in brackets, so the
       brackets have to hold something. *)
    (match rest with
     | (Token.RParen, _) :: _ -> false
     | _ -> go 0 rest)
  | _ -> false

(* Absorption at the head of a spine is harmless while the name is bare:
   `S (x)` and `S x` both build `App (S, x)`, so there is nothing to guard
   against. Qualified, it is not -- `l.A (x)` puts the application inside
   the qualification, `l.(A x)`, where the spine wants it outside,
   `(l.A) x`. So a qualified head facing a bracket needs one of its own. *)
let head_needs_a_bracket e =
  match strip_located e with
  | Qualified (_, inner) -> absorbs_a_bracket inner
  | _ -> false

let bracket_if_wrapped_app body emitted =
    (* Both conditions, and only together. A `match` or an `if` is safe
       wherever it breaks, because its parse is not finished there -- the
       cases are still owed. An application's is: it ends at the first line
       end that leaves nothing open, and what follows is read as something
       new. *)
    if breaks_at_depth_zero emitted && wrapping_ends_it body
    then bracket emitted
    else emitted

(* Every layout this file has produced for the item being written, keyed by
   where the expression came from and where it is being put.

   The emitters ask twice. To know whether a value fits on one line they lay
   it out and measure it; if it does not, they lay it out again at the
   indent it will really sit at. Each of those two layouts asks the same
   question of every child, so the cost doubles with every level of nesting
   -- a `let ... in` chain fourteen deep took two minutes, and the shapes
   that reach that depth are ordinary code at a narrow margin. Found by
   test/fuzz, which draws a margin per input and so keeps meeting them.

   The key is the expression's own span in the source, which is unique and
   two integers, rather than the expression itself, which would have to be
   hashed and compared. Only a `Located` node has one; anything else is laid
   out as before, which costs nothing extra because its parent is cached.

   The margin is in the key as well, because a probe asks what the layout
   would be at an unbounded one and the answer must not be handed back as
   the layout at the real one.

   Emptied for each top-level item, because the interior comments a layout
   may have read are fixed for the length of one item and not beyond it. *)
(* Keyed by the expression itself, compared by identity.

   A key made from the source span was the first attempt, and it covered
   almost nothing: only a few hundred of a file's expression nodes carry a
   location. Counted on one input, 1,049,210 layouts went uncached against
   841 cached ones, and the walk stayed exponential while the layouts it
   produced were being reused.

   Physical equality needs no location and is sound: the same node, at the
   same indent and column, under the same margin, lays out the same way. The
   hash mixes those three with a shallow hash of the node, so nodes of the
   same shape do not pile into one bucket; comparison is `==`, which costs
   nothing when they do. *)
module Layout_key = struct
  type t = expr * int * int * int
  let equal (a, i1, c1, w1) (b, i2, c2, w2) =
    a == b && i1 = i2 && c1 = c2 && w1 = w2
  let hash (e, i, c, w) = Hashtbl.hash (Hashtbl.hash_param 8 32 e, i, c, w)
end

module Layouts = Hashtbl.Make (Layout_key)

let layouts : string Layouts.t = Layouts.create 1024

let rec emit_expr ?col indent e =
  let key = (e, indent, (match col with Some c -> c | None -> indent), !max_width) in
  match Layouts.find_opt layouts key with
  | Some text -> text
  | None ->
    let text = emit_expr_inner ?col indent (strip_located e) in
    Layouts.replace layouts key text;
    text

(* App-chain function/argument positions require strict "atom" syntax --
   a bare BinOp/UnOp/If/Match/Fn/Let there would be reparsed differently
   (or rejected outright), so always parenthesize those; everything else
   (literals, Var, Field, another App, Tuple/List/MapLit, ...) is already
   safe unwrapped in that position. *)
(* A parenthesized expression that ran onto more lines closes on a line of
   its own, at the indent that opened it. Trailing the last line, the closing
   bracket joins a stack of `))` that says nothing about which of them ends
   what -- and the last line of a `match` is its final case, where a `)` is
   easiest of all to misread as part of the case.

   Two closing lines in a row are the same noise one column over, so a
   bracket whose content already closed at this indent joins that line
   instead of opening another. *)
and parenthesize indent s =
  if not (String.contains s '\n') then bracket s
  else
    let ind = String.make indent ' ' in
    (* Unless what is being wrapped already closed on a line of its own, at
       the same indent -- a lambda around a block opens both brackets on one
       line, and closing them on two says nothing the one line does not.
       Which bracket closed there does not matter: `]` at this indent ends a
       line as plainly as `)` does, and a `)` alone on the next one repeats
       it a column over. *)
    let closed_here =
      List.exists (fun c -> String.ends_with ~suffix:("\n" ^ ind ^ c) s)
        [")"; "]"; "}"]
    in
    if closed_here then bracket s
    else bracket (s ^ "\n" ^ ind)

(* What goes between `%{` and `}`. A newline in there ends the string as far
   as the lexer is concerned, and the rest of the splice is then read as
   something else -- an argument below the break simply disappeared. So a
   splice is rendered against a margin nothing reaches, and comes back on one
   line however long it is. *)
and emit_splice indent e = with_width 1_000_000 (fun () -> emit_expr indent e)

and emit_atom indent e =
  let e' = strip_located e in
  let s = emit_expr_inner indent e' in
  if is_control_expr e' || is_binop_or_unop e' || is_app e'
  then parenthesize indent s else s

(* An argument is an atom. A bare constructor is one hazard on top of that,
   and the hazard is narrower than it looks: a constructor absorbs a
   following *bracketed* expression and nothing else.

     f None (x)     is  f (None x)
     f None x       is  (f None) x
     f None [1]     is  (f None) [1]
     f None 1       is  (f None) 1

   So a constructor argument needs brackets exactly when the text after it
   opens with `(`. That is a question about the rendering, not about the
   position -- and position is what this used to ask, bracketing every
   constructor that was not the last argument. Two things went wrong. It
   added brackets nothing needed, and after a qualified name those brackets
   changed the parse: `l.A S a` is `(l.A S) a`, while `l.A (S) a` reads `S`
   as the payload of `l.A`. The formatter wrote each spelling as the other
   and never settled. Found by test/fuzz.

   `following` is what comes after the last of these, when the caller has
   already decided it -- a trailing lambda renders as `(fn ...`, which a
   constructor before it would absorb just the same.

   Right to left, because a bracket written onto one argument is the next
   one's business too: it is the text the argument before it now faces. Asked
   left to right against the unguarded renderings, the guard fixed one
   position and opened the same hole one place to its left -- `(f S S) (B m)`
   came back as `f S (S) (B m)`, where the two constructors read as one
   application. Every argument absorbs only the bracket directly after it, so
   working backwards settles in one pass, and it settles against the head,
   which `guard_spine` guards. Found by test/fuzz, three times. *)
and guard_constructors args rendered following =
  let args = Array.of_list args and rendered = Array.of_list rendered in
  let n = Array.length rendered in
  let out = Array.make n "" in
  for i = n - 1 downto 0 do
    let next = if i + 1 < n then out.(i + 1) else following in
    let absorbs = next <> "" && next.[0] = '(' in
    out.(i) <-
      (if absorbs && absorbs_a_bracket args.(i) then bracket rendered.(i)
       else rendered.(i))
  done;
  Array.to_list out

(* The spine as its pieces, head first, each guarded against the one after
   it. The head is here because it is where a run of constructors stops:
   guarding the arguments alone left `(l.A S) (B m)` to come back as
   `l.A (S) (B m)`, which reads `S` as the payload of `l.A`. *)
and guard_spine head head_s args rendered following =
  let guarded = guard_constructors args rendered following in
  let next = match guarded with x :: _ -> x | [] -> following in
  let head_s =
    (* A qualified head needs its brackets whatever follows. A bare one needs
       them only where absorption is not the identity it is claimed to be --
       which `bracket_holds_all` is the test for.

       `"("` is not a rendering. It is the sentinel the trailing-lambda
       branch passes to say a wholly bracketed argument is coming, and
       reading it as one made `bracket_holds_all` answer no to a bracket
       that does hold everything -- so `Kach (fn ...)` came back as
       `(Kach) (fn ...)` and, qualified, as the unparseable `t.(Kach)`. *)
    let whole_bracket_follows = next = "(" || bracket_holds_all next in
    if next <> "" && next.[0] = '('
       && (head_needs_a_bracket head
           || (absorbs_a_bracket head && not whole_bracket_follows))
    then bracket head_s
    else head_s
  in
  head_s :: guarded

and emit_arg indent e = emit_atom indent e

and emit_expr_inner ?col indent e =
  let col = match col with Some c -> c | None -> indent in
  match e with
  | Int n      -> string_of_int n
  | Float f    -> string_of_wand_float f
  | String s   ->
    if prefers_raw s then "`" ^ s ^ "`"
    else "\"" ^ escape_string_body s ^ "\""
  | Bool b     -> string_of_bool b
  | Unit       -> "()"
  | Path s | Glob s | DateTime s | Duration s
  | URL s | CIDR s | Version s | Size s | IPv4 s -> s
  | Port n     -> ":" ^ string_of_int n
  | Var x      -> x
  | Constr x   -> x
  | EnvVar x   -> "$" ^ x
  | Hole       -> "?"
  | App _      -> emit_app ~col indent e
  | Fn (ps, body) ->
    (* The body is written after `fn params -> `, so that is where it
       starts -- an `if` in here was the other half of this bug. *)
    let head = emit_fn_head ps ^ " " in
    (* A wrapped application as the body ends at its first line, and what is
       left below it reads as something new -- the same hazard a binding's
       body has, and the lambda gives it no bracket of its own. *)
    (* A `let ... in` chain lays its continuation out at the indent it is
       handed, so hand it one under the lambda: level with the `fn`, the
       second binding reads as the statement after the lambda rather than
       as the rest of its body. An `if` or a `match` places itself from the
       column it starts at and already sits where it should. *)
    let body_indent =
      match strip_located body with
      | Let (_, _, _, LetIn) | LetRec (_, _, LetIn) -> indent + 2
      | _ -> indent
    in
    head
    ^ bracket_if_wrapped_app body
        (emit_expr ~col:(col + String.length head) body_indent body)
  (* A binding written with the `;` of a block belongs to that block, and
     comes back out with the `;`. *)
  | (Let (_, _, _, LetBlock) | LetRec (_, _, LetBlock)) as e ->
    emit_block ~col indent e
  | Let (p, e1, e2, LetIn) -> emit_let ~col indent p e1 e2
  | LetRec (bindings, e2, LetIn) -> emit_letrec indent bindings e2
  | If (c, t, el) -> emit_if ~col indent c t el
  | Match (scr, cases) -> emit_match ~col indent scr cases
  | BinOp (op, a, b) -> emit_binop ~col indent op a b
  | UnOp (op, e) ->
    (* A space where the two would lex as one token. `-` against a path or a
       glob starting `.` makes `-.`, which the lexer reports as a float
       operator wand does not have -- so `- ./` came back unreadable. `!` has
       the same hazard in front of `=`. The space is only written where it is
       needed, so `-x` and `!ok` are untouched. Found by test/fuzz. *)
    let arg = emit_atom indent e in
    let glues =
      arg <> ""
      && (match op, arg.[0] with
          | "-", ('.' | '-') -> true
          | "!", '=' -> true
          | _ -> false)
    in
    op ^ (if glues then " " else "") ^ arg
  (* An item is placed two columns in, so that is the indent it wraps to --
     rendering it at the sequence's own indent puts an item's continuation
     lines to the left of the item itself. *)
  | Tuple es -> emit_sequence ~col indent "(" ")" (List.map (emit_expr (indent + 2)) es)
  | List es  -> emit_list ~col indent es
  | ConstrBare (name, ids) -> name ^ "(" ^ String.concat ", " ids ^ ")"
  | Qualified (m, e) ->
    (* A constructor reached through its module takes the bracket written
       after it. That bracket puts the payload inside the module. `d.M(N)`
       reads `N` in `d`. `d.M N` applies `d.M` to an `N` read outside `d`.
       The payload's scope is the difference.

       The bracket was dropped, so each form was written as the other.
       `n d.M(N) (s [])` became `n d.M N (s [])`. The loose `N` then took
       the bracket after it, and the formatter did not settle. Found by
       test/fuzz. *)
    (match strip_located e with
     | App (f, arg) when (match strip_located f with Constr _ -> true | _ -> false) ->
       let payload = match strip_located arg with
         (* The tuple's own brackets serve as the constructor's, as in
            `M(a, b)`. *)
         | Tuple es -> String.concat ", " (List.map (emit_expr indent) es)
         | _ -> emit_expr indent arg
       in
       m ^ "." ^ emit_expr indent f ^ "(" ^ payload ^ ")"
     | _ -> m ^ "." ^ emit_expr indent e)
  | ConstrApp (name, kvs) ->
    (* Punned only where every field puns, and there are two or more of
       them. That is the whole of what reads back as a construction: one
       identifier alone is a payload (`B(n)`), and a pun standing in front
       of a named field is the record update `T(r, b = 3)`, which took the
       punned name as the record to update -- `M(a = x, b = "z")` came back
       as `M(x, b = "z")` and stopped typechecking, or worse, typechecked
       against a free variable and built something else. The pattern side
       may pun beside a named field because it has no update form to collide
       with. *)
    let puns (k, v) =
      match k, strip_located v with
      | Some n, Var x when x = n -> true
      | _ -> false
    in
    let all_pun = List.length kvs >= 2 && List.for_all puns kvs in
    let field (k, v) =
      if all_pun then (match k with Some n -> n | None -> "")
      else
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
             if all_pun then (match k with Some n -> n | None -> "")
             else
               let label = match k with Some n -> n ^ " = " | None -> "" in
               (* The value is written after its field name, so that is where
                  it starts. *)
               label ^ emit_expr ~col:(indent + 2 + String.length label) (indent + 2) v) kvs)
      ^ "\n" ^ ind ^ ")"
  (* `T(r, a = 1)`: the base reads as the first item, and the fields that
     change follow it, so the one-per-line form puts the base on its own
     line as well. *)
  | ConstrUpdate (name, base, kvs) ->
    let items =
      emit_expr indent base
      :: List.map (fun (k, v) -> k ^ " = " ^ emit_expr indent v) kvs
    in
    let body = String.concat ", " items in
    let oneline = name ^ opener "(" body ^ body ^ ")" in
    if fits col oneline then oneline
    else
      let ind = String.make indent ' ' in
      let inner = String.make (indent + 2) ' ' in
      let lines =
        emit_expr (indent + 2) base
        :: List.map (fun (k, v) ->
             let label = k ^ " = " in
             label ^ emit_expr ~col:(indent + 2 + String.length label) (indent + 2) v) kvs
      in
      name ^ "(\n" ^ inner ^ String.concat (",\n" ^ inner) lines ^ "\n" ^ ind ^ ")"
  | Field (e, l) -> emit_field indent e l
  | Seq _ as e -> emit_block ~col indent e
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
     would hand the whole thing to the shell as one word.

     A bracket written straight onto the `$` is that literal text; one
     written after a space is an expression that answers with the command.
     `$(i)` runs the command `i`, and `$ (i)` runs whatever the value `i`
     holds -- two different programs, told apart by a space. So the space is
     written back where the body is an expression, and withheld where it is
     the text. Printing both as `$(...)` turned the second into the first,
     silently. Found by test/fuzz. *)
  | RunCmd (e, _)   -> "$" ^ command_body indent e
  (* `$?` has no spelling with a space: `$? (e)` does not lex as a query at
     all, and the parser builds a `RunQuery` only from the tight form. So
     its body is always the text, and always written tight. *)
  | RunQuery (e, _) -> "$?(" ^ emit_command indent e ^ ")"
  (* `$*` is the same: only the tight form lexes, so the body is always the
     command text. *)
  | MkCommand (e, _) -> "$*(" ^ emit_command indent e ^ ")"
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
      Buffer.add_string buf (emit_splice indent e);
      Buffer.add_char buf '}'
    ) parts;
    Buffer.add_string buf tail;
    Buffer.add_char buf '`';
    Buffer.contents buf
  | Interp (parts, tail) ->
    (* The same backtick preference as a plain String: when some literal
       piece escapes a quote and every piece survives rawly, the whole
       template moves between backticks -- `%{...}` interpolates there
       too, so the splices carry over untouched. *)
    let lits = List.map fst parts @ [tail] in
    let raw = List.exists (fun s -> String.contains s '"') lits
              && List.for_all raw_safe lits in
    let quote = if raw then "`" else "\"" in
    let lit_body s = if raw then s else escape_string_body s in
    let buf = Buffer.create 32 in
    Buffer.add_string buf quote;
    List.iter (fun (lit, e) ->
      Buffer.add_string buf (lit_body lit);
      (* `$NAME` is plain text in a string now, so an env read has to be
         written out as the expression it is: `%{$HOME}`. *)
      Buffer.add_string buf "%{";
      Buffer.add_string buf (emit_splice indent e);
      Buffer.add_char buf '}'
    ) parts;
    Buffer.add_string buf (lit_body tail);
    Buffer.add_string buf quote;
    Buffer.contents buf
  (* Only reachable inside `$()`, which `emit_cmd` handles; rendered here so
     the match is total and so a stray one is still legible. *)
  | CmdInterp (parts, tail) ->
    let buf = Buffer.create 32 in
    List.iter (fun (lit, e, h) ->
      Buffer.add_string buf lit;
      Buffer.add_string buf
        (match (h : Token.hole) with Token.Source -> "%!{" | _ -> "%{");
      Buffer.add_string buf (emit_splice indent e);
      Buffer.add_char buf '}'
    ) parts;
    Buffer.add_string buf tail;
    Buffer.contents buf
  | Handle (body, cases) ->
    (* Same stepping rule as emit_match: arms of a `handle` that starts
       mid-line indent past the line that introduced it. *)
    let arm_indent = if col > indent then indent + 2 else indent in
    let emit_arm = function
      | EffectCase (op, p, k, b) ->
        Printf.sprintf "| %s %s %s -> %s" op (emit_pat p) k (emit_case_body arm_indent b)
      | ReturnCase (p, b) ->
        Printf.sprintf "| return %s -> %s" (emit_pat p) (emit_case_body arm_indent b)
    in
    (* `with` has to follow the body, so a body that wrapped puts the
       keyword out of the parser's reach. `with ... as` has the same shape,
       and its rule -- bracket an application whose first line closed
       everything it opened -- is not enough here: a body can open a bracket
       on its first line, close it on a later one, and still leave text
       after that for the newline to cut off. Any body that wrapped at all
       gets the brackets. *)
    let emitted_body = emit_expr indent body in
    let wrapped = String.contains emitted_body '\n' in
    let head = if wrapped then bracket emitted_body else emitted_body in
    (* The arms carry the line break, so with no arms there is no break to
       carry. Emitting one anyway left a trailing newline that the item
       joiner then separated from the next item, so `handle () with` grew a
       blank line under it on every pass and `wand f` run twice was not
       `wand f` run once. Found by test/fuzz.

       Only `handle` needs this. A `match` with no cases does not parse at
       all -- "match has no cases" -- so the same shape there is a state no
       source can reach. *)
    "handle " ^ head ^ " with"
    ^ (match cases with
       | [] -> ""
       | _ ->
         let pad = String.make arm_indent ' ' in
         "\n" ^ pad ^ String.concat ("\n" ^ pad) (List.map emit_arm cases))
  | Try e -> "try " ^ emit_expr indent e
  (* The body stays at the bracket's own indentation rather than stepping in.
     Brackets nest -- a temp dir holding a lock holding a directory change --
     and indenting each one would push the actual work off the page for
     something that reads as a preamble, not as nesting. *)
  | With (r, p, body) ->
    (* `as` has to follow the resource, so one that wrapped puts the keyword
       out of the parser's reach. *)
    let head =
      Printf.sprintf "with %s as %s ->"
        (bracket_if_wrapped_app r (emit_expr indent r)) (emit_pat p) in
    (* A body that opens a bracket of its own opens it on the `->` line and
       lets the items carry the break, as a binding's value does. Given a
       line to itself the bracket says nothing: the items sit at the same
       column either way, and the `(` costs a line at the top of every
       `with` wide enough to wrap. It is laid out from where it lands, three
       columns past the `->`, so it wraps against the room it really has. *)
    if opens_a_bracket body then
      head ^ " " ^ emit_expr ~col:(col + String.length head + 1) indent body
    else
      let one_line = head ^ " " ^ emit_expr indent body in
      if fits col one_line then one_line
      else head ^ "\n" ^ String.make indent ' ' ^ emit_expr indent body
  | Annot (te, e) -> emit_atom indent e ^ " : " ^ emit_type_expr te
  | MapLit kvs ->
    (* Measured from where the brace actually lands, as the other two
       bracket forms are: a map cuddled onto a binding's line starts well
       right of the indent it wraps to. *)
    emit_sequence ~col indent "{" "}"
      (List.map (fun (k, e) -> map_key k ^ " = " ^ emit_expr (indent + 2) e) kvs)

and emit_app ?col indent e =
  let col = match col with Some c -> c | None -> indent in
  (* Not through a module's name. The parser builds `p.M N` as
     `App (Qualified (p, M), N)`. It builds `p.M(N)` as
     `Qualified (p, App (M, N))`. These are two programs. The bracket puts
     the payload inside the module: `foo.Boxed(Red)` reads `Red` as `foo`'s
     constructor, and `foo.Boxed Red` looks for `Red` outside `foo`.

     This did flatten through `Qualified`. That brought the constructor out
     where `guard_constructors` could see it, and it wrote `p.M(N)` as
     `p.M N`. The payload changed scope. `emit_expr_inner`'s `Qualified`
     keeps the bracket now, so the payload stays in the constructor's own
     bracket and the guard is owed nothing. Found by test/fuzz twice: as
     the instability, then as this. *)
  let rec flatten e = match strip_located e with
    | App (f, x) -> let (h, args) = flatten f in (h, args @ [x])
    | other -> (other, [])
  in
  let (head, args) = flatten e in
  if args = [] then emit_expr indent head
  else
    (* The head travels with the arguments: guarding one of them can put a
       bracket in front of the head, so the two cannot be joined afterwards. *)
    let spine ?(following = "") ind =
      guard_spine head (emit_atom indent head) args
        (List.map (emit_arg ind) args) following
    in
    (* Asked at an unbounded margin, where nothing can choose to wrap. This
       is the one shape the cache cannot help on its own: the two questions
       are asked at two different indents, so neither answer is the other's.
       Asked flat, the question costs one pass over the subtree. *)
    let oneline =
      with_width max_int (fun () -> String.concat " " (spine indent))
    in
    if fits col oneline then oneline
    else
      (* Too wide. A trailing lambda is the common shape -- `test "..." (fn t
         -> ...)` -- and reads best with its body on the next line, the way
         it would have been written by hand. *)
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
                (guard_spine head (emit_atom indent head) before
                   (List.map (emit_arg indent) before) "(")
            in
            let head_s =
              prefix ^ " (" ^ emit_fn_head ps in
            (* A bracketed body opens on the arrow's line, as it does after
               an `=`, rather than spending a line on a bracket alone. *)
            if opens_a_bracket body then
              head_s ^ " " ^ emit_expr ~col:(indent + String.length head_s + 1) indent body ^ ")"
            else head_s ^ "\n" ^ inner ^ emit_expr (indent + 2) body ^ ")"
          (* A trailing bracket is the other common shape -- `report [...]`,
             `handle {...}` -- and reads the way a trailing lambda does: the
             bracket opens on the call's own line and the items carry the
             break. One argument per line under the head instead would spend
             a line on the bracket alone and push every item two columns
             further in, and would leave the call's first line closed, which
             costs it a pair of parentheses on top. *)
          | last_v when opens_a_bracket last_v ->
            let tail = emit_expr ~col:0 indent last_v in
            let prefix =
              String.concat " "
                (guard_spine head (emit_atom indent head) before
                   (List.map (emit_arg indent) before) tail)
            in
            prefix ^ " "
            ^ emit_expr ~col:(column_after col prefix + 1) indent last_v
          | _ ->
            (* Otherwise one argument per line, under the head. A newline
               does not stop a constructor absorbing the bracket below it --
               the parser's lookahead steps over one -- so the guard applies
               to this layout exactly as it does to the flat one. *)
            (match spine (indent + 2) with
             | head_s :: rest ->
               head_s ^ "\n" ^ inner ^ String.concat ("\n" ^ inner) rest
             | [] -> oneline))
       | _, None -> oneline)

(* What follows the `$`, brackets and all: the literal text spelled tight
   against the bracket, or the expression spelled a space away from it. *)
and command_body indent e =
  match strip_located e with
  | String _ | Interp _ | CmdInterp _ | RawString _ | RawInterp _ ->
    bracket (emit_command indent e)
  | _ -> " (" ^ emit_expr indent e ^ ")"

(* A command's text, with interpolations left as %{...} and nothing quoted. *)
and emit_command indent e =
  match strip_located e with
  | String s -> s
  | Interp (parts, tail) ->
    let buf = Buffer.create 32 in
    List.iter (fun (lit, ex) ->
      Buffer.add_string buf lit;
      Buffer.add_string buf "%{";
      Buffer.add_string buf (emit_splice indent ex);
      Buffer.add_char buf '}') parts;
    Buffer.add_string buf tail;
    Buffer.contents buf
  (* Which form each interpolation used has to survive formatting: rewriting
     `%!{x}` as `%{x}` would quietly quote a splice that was meant to be
     shell source, and the script would stop working. *)
  | CmdInterp (parts, tail) ->
    let buf = Buffer.create 32 in
    List.iter (fun (lit, ex, h) ->
      Buffer.add_string buf lit;
      Buffer.add_string buf
        (match (h : Token.hole) with Token.Source -> "%!{" | _ -> "%{");
      Buffer.add_string buf (emit_splice indent ex);
      Buffer.add_char buf '}') parts;
    Buffer.add_string buf tail;
    Buffer.contents buf
  | other -> emit_expr indent other

and emit_field indent e l =
  let e' = strip_located e in
  (* A literal that ends in a digit keeps its brackets, because the `.` that
     follows would otherwise be read as part of the number: `(6).o` written
     as `6.o` is not a field access, it is a float missing its fraction, and
     the lexer says so. A name ending in a digit is safe -- `x1.field` reads
     as a field access, because the token did not start as a number -- so
     this asks what the expression is as well as how it ends. Found by
     test/fuzz. *)
  let numeric_literal = match e' with
    | Int _ | Float _ | Port _ | IPv4 _ | CIDR _
    | DateTime _ | Duration _ | Size _ -> true
    | _ -> false
  in
  let ends_in_a_digit t =
    t <> "" && (match t.[String.length t - 1] with '0' .. '9' -> true | _ -> false)
  in
  (* The target is an atom, which is what `.` binds to. It was a list of
     the forms that need brackets, and the list left `App` out -- so
     `(S 6).o` came back as `S 6.o`, which is a different program before it
     is a lex error. `emit_atom` already knows every form that has to be
     bracketed in this position, including that one. *)
  (* A literal whose lexeme runs on into the `.` keeps its brackets whatever
     it ends in, because there is no spelling of it that does not. `.` is a
     path body character and a URL runs to the punctuation around it, so
     `(./p).log` written as `./p.log` is one path token, not a field access
     -- a different program, and one that typechecks, so nothing downstream
     says a word. Bracketed source lost its brackets here too, which is why
     no file in the corpus showed it. Found by test/fuzz. *)
  (* `import` renders as the keyword and then a path or a module name, and
     the `.` runs into whichever it is: `(import /t).s` written as
     `import /t.s` imports a different file, and `(import FS).s` written as
     `import FS.s` names a different module. Both were an error about where
     `import` may appear and became an error about a missing file, which is
     a different program answering a different question. The hazard is the
     rendering's last token, not the node -- an `import` is the case where
     those differ. Found by test/fuzz. *)
  (* A version runs into the `.` whatever it ends in, so it belongs here
     rather than with the literals that only do it when they end in a digit.
     `1.0.0` was caught by that rule and `1.0.0-a` was not: a prerelease is
     dot-separated, so `(1.0.0-a).f` written as `1.0.0-a.f` is the single
     version `1.0.0-a.f`. The field access became a version literal, and the
     file went from a type error to typechecking. Found by test/fuzz. *)
  let lexeme_eats_the_dot = match e' with
    | Path _ | Glob _ | URL _ | EnvVar _ | ImportExpr _ | Version _ -> true
    | _ -> false
  in
  let target =
    let t = emit_atom indent e' in
    if lexeme_eats_the_dot || (numeric_literal && ends_in_a_digit t) then
      bracket t
    else t
  in
  target ^ "." ^ l

(* Items on one line while they fit, one per line when they do not. The
   brackets carry the break rather than the items being aligned under the
   opening one: alignment moves every line when the head changes, which
   makes a diff of a formatted file larger than the edit that caused it. *)
(* A list whose elements have comments between them. The elements carry
   locations, so the same previous-sibling window the arms of a `match` use
   applies; a list that takes one is written one element per line, because a
   comment cannot sit inside `[a, b]`. *)
and emit_list ?col indent es =
  let col = match col with Some c -> c | None -> indent in
  let prev_end = ref max_int in
  let claimed = ref false in
  let piece e =
    let above =
      match loc_of e with
      | None -> []
      | Some l ->
        let cs = comments_between !prev_end l.Token.offset in
        if cs <> [] then claimed := true;
        List.map (fun c -> c.c_text) cs
    in
    let text = emit_expr (indent + 2) e in
    (match loc_of e with
     | Some l -> prev_end := l.Token.end_offset
     | None -> prev_end := max_int);
    (above, text)
  in
  let parts = List.map piece es in
  if not !claimed then
    emit_sequence ~col indent "[" "]" (List.map snd parts)
  else begin
    let inner = String.make (indent + 2) ' ' in
    let buf = Buffer.create 128 in
    let n = List.length parts in
    Buffer.add_string buf "[\n";
    List.iteri (fun i (above, text) ->
      List.iter (fun c -> Buffer.add_string buf (inner ^ c ^ "\n")) above;
      Buffer.add_string buf (inner ^ text);
      if i < n - 1 then Buffer.add_string buf ",\n"
    ) parts;
    Buffer.add_string buf ("\n" ^ String.make indent ' ' ^ "]");
    Buffer.contents buf
  end

and emit_sequence ?col indent opening closing items =
  let col = match col with Some c -> c | None -> indent in
  let body = String.concat ", " items in
  let oneline = opener opening body ^ body ^ closing in
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
  let piece side e =
    match strip_located e with
    | (Try _ | Handle _ | Contract _ | Fn _ | If _ | Match _
      | Let _ | LetRec _ | With _) as inner -> bracket (emit_expr indent inner)
    (* A stage that is an operator of its own keeps the brackets `emit_binop`
       would have given it, and did not: the stages are read back as one
       left-associative chain, so an operator on the right of a `|>` needs
       them unless its precedence clears `|>`'s outright. `5 |> (f |> g)`,
       laid out a stage per line, came back as `(5 |> f) |> g` -- a different
       program, and the reprint of that was different again, which is how the
       fuzzer saw it. Found by test/fuzz. *)
    | BinOp (op2, _, _) as inner ->
      let prec = bin_prec "|>" and cp = bin_prec op2 in
      let rendered = emit_expr (indent + 2) inner in
      if cp > prec || (cp = prec && side = `Left)
      then bracket_if_wrapped_app e rendered
      else bracket rendered
    (* A stage that wrapped ends at its first line; the `|>` leading the
       next stage says nothing about the argument left below this one. *)
    | _ -> bracket_if_wrapped_app e (emit_expr (indent + 2) e)
  in
  match all with
  | [] -> ""
  | first :: rest ->
    let inner = String.make (indent + 2) ' ' in
    piece `Left first
    ^ String.concat ""
        (List.map (fun e -> "\n" ^ inner ^ "|> " ^ piece `Right e) rest)

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
      if ok then inner else bracket inner
    (* These extend as far to the right as they can, so an operand needs
       parentheses or the operator is swallowed into it: `(try e) == x`
       printed bare re-parses as `try (e == x)`. *)
    | (Try _ | Handle _ | Contract _ | Fn _ | If _ | Match _
      | Let _ | LetRec _) as inner -> bracket (emit_expr indent inner)
    (* An operand that wrapped ends at its first line, so the rest of it
       reads as something new -- the operator having said nothing about how
       far its right side goes. *)
    | _ -> bracket_if_wrapped_app e (emit_expr indent e)
  in
  let oneline = Printf.sprintf "%s %s %s" (side_str `Left a) op (side_str `Right b) in
  if op = "|>" && not (fits col oneline) then emit_pipeline indent a b
  else oneline

(* If `body` is `Annot (te, real_body)` -- a return-type annotation on a
   function clause (`let f x : T = body`) -- return the ": T" to append to
   the clause head and the real body to print after `=`. Printed after `=`
   instead, `: T` is ambiguous with the cons operator (same hazard as
   emit_let's own Annot case below), so it must move before it. *)
(* A comment between a definition's `=` and the body it introduces -- the
   first thing inside the definition. The item's start bounds it below, and
   only `let name params =` lies in between. *)
and body_lead e =
  match loc_of e with
  | Some l -> comments_between !item_start l.Token.offset
  | None -> []

and with_body_lead head indent e fallback =
  match body_lead e with
  | [] -> fallback ()
  | cs ->
    let inner = String.make (indent + 2) ' ' in
    head ^ " =\n"
    ^ String.concat "" (List.map (fun c -> inner ^ c.c_text ^ "\n") cs)
    ^ inner ^ emit_expr (indent + 2) e

and split_clause_annot body =
  match strip_located body with
  | Annot (te, real_body) -> (" : " ^ emit_type_expr te, real_body)
  | _ -> ("", body)

(* The clauses of `let name params = body`, without the `in` that follows
   them. A binding in a block has no `in`, and both spellings have to lay
   the clauses out the same way. *)
(* A block: statements in parentheses, where a binding may run to the end of
   it. `(let x = 1; a; b)` parses to `Let (x, 1, Seq (a, b), LetBlock)`, so
   the walk goes through a binding as well as through a `Seq`.

   The two spellings of a binding say the same thing, and which one a node
   holds is the one the author wrote. So a block ends where the `;`s do,
   whatever the last statement turns out to be: `(let x = 1; f x)` is a
   block of two statements, and `let x = 1 in f x` is not. *)
and is_block e =
  match strip_located e with
  | Seq _ | Let (_, _, _, LetBlock) | LetRec (_, _, LetBlock) -> true
  | _ -> false

and emit_block ?col indent e =
  let col = match col with Some c -> c | None -> indent in
  (* Statements are the other boundary a comment sits at. Each carries a
     location, so the same previous-sibling window applies. A statement is
     paired with the comments above it rather than joined to them, because
     the `;` between statements must not land after a comment.

     The first statement has no sibling before it, and the block's own `(`
     is not in the AST, so there is nothing to open its window against. It
     claims nothing: a comment above the first statement leaves the item
     verbatim rather than risk being lifted out of the construct that
     encloses the block. *)
  let prev_end = ref max_int in
  let claimed = ref false in
  (* The comments above a statement that starts at `hi`. *)
  let lead hi =
    let cs = comments_between !prev_end hi in
    if cs <> [] then claimed := true;
    List.map (fun c -> c.c_text) cs
  in
  (* Where a statement starts. A `let` in a block is not wrapped in a
     `Located` -- the keyword is consumed before the node is built -- so its
     value's start stands in. The only text between the two is `let <pat> =`,
     which no comment can sit inside without ending the line. *)
  let starts_at = function
    | Some (l : Token.loc) -> Some l.Token.offset
    | None -> None
  in
  let advance_past = function
    | Some (l : Token.loc) -> prev_end := l.Token.end_offset
    | None -> prev_end := max_int
  in
  let rec items ind e =
    match strip_located e with
    | Seq (a, b) ->
      let above = match starts_at (loc_of a) with Some hi -> lead hi | None -> [] in
      (* Every statement but the last is followed by a `;`, so one ending in
         an arm gets the bracket that keeps the two apart. Laid out one
         column further in, because the bracket takes that column and the
         arms belong under the `match` rather than under its `(`. *)
      let a_text =
        if ends_in_an_arm a then bracket (emit_expr (ind + 1) a)
        else emit_expr ind a
      in
      advance_past (loc_of a);
      (above, a_text) :: items ind b
    (* A binding reached here is one of the block's statements, so it takes
       the block's `;` whatever joined it to its body in the source. The tag
       cannot decide this on its own: `(t; (let f = e in ()))` loses the
       brackets the binding wore, which puts it in the block, and a binding
       written `in` with statements above it stands beside their `;`. Only
       the printer knows what the brackets will be.

       The `in` that narrows is not reached here. It is a `Seq`'s first
       child, which the case above emits as a statement, so `(let x = 1 in
       x + 1; 9)` keeps the `in` that holds `x` off the `9`. Nor is a
       binding that is not in a block: `emit_block` is reached only for a
       `Seq` or a block binding, so the first call here is never a bare
       `let ... in`. *)
    | Let (p, e1, body, _) ->
      let above = match starts_at (loc_of e1) with Some hi -> lead hi | None -> [] in
      let text = emit_binding ~col:ind ind p e1 in
      advance_past (loc_of e1);
      (above, text) :: items ind body
    | LetRec (bindings, body, _) ->
      let above =
        match bindings with
        | (_, _, first) :: _ ->
          (match starts_at (loc_of first) with Some hi -> lead hi | None -> [])
        | [] -> []
      in
      let text = emit_letrec_bindings ind bindings in
      (match List.rev bindings with
       | (_, _, last) :: _ -> advance_past (loc_of last)
       | [] -> prev_end := max_int);
      (above, text) :: items ind body
    | other ->
      let above = match starts_at (loc_of e) with Some hi -> lead hi | None -> [] in
      [(above, emit_expr ind other)]
  in
  (* The one-line form is measured at this indent and the wrapped one two
     further in, so the walk runs twice. Reading comments does not consume
     them, so the second walk sees what the first did; `prev_end` is put
     back so its windows open in the same places. *)
  (* Asked at an unbounded margin, for the reason the application's probe is:
     the measuring walk and the real one run at two different indents, so
     neither answer is the other's and the cache cannot pair them. Flat, the
     question costs one pass. *)
  let probe = with_width max_int (fun () -> items indent e) in
  let probe_claimed = !claimed in
  prev_end := max_int; claimed := false;
  let oneline = bracket (String.concat "; " (List.map snd probe)) in
  if not probe_claimed && fits col oneline && not (String.contains oneline '\n')
  then oneline
  else begin
    let stmts = items (indent + 2) e in
    let ind = String.make indent ' ' in
    let inner = String.make (indent + 2) ' ' in
    let buf = Buffer.create 128 in
    let n = List.length stmts in
    Buffer.add_string buf "(\n";
    List.iteri (fun i (above, text) ->
      List.iter (fun c -> Buffer.add_string buf (inner ^ c ^ "\n")) above;
      Buffer.add_string buf (inner ^ text);
      if i < n - 1 then Buffer.add_string buf ";\n"
    ) stmts;
    Buffer.add_string buf ("\n" ^ ind ^ ")");
    Buffer.contents buf
  end

and emit_fn_clauses ~col indent p params fbody =
  let name = match p with PVar n -> n | _ -> "_" in
  let clauses = match try_multi_equation params fbody with
    | Some cs -> cs
    | None    -> [(params, fbody)]
  in
  (* Every clause repeats `let`, and every clause sits at the same indent.
     The continuation used to be the bare name, aligned under the first --
     and that spelling only parses where a newline ends an expression, which
     is to say at bracket depth zero. Inside a `( ... )` a newline continues
     the expression instead, so the bare `count log = 2` was read as more of
     the previous clause's body and the `=` had nowhere to go.

     Repeating `let` parses in all three places: at the top level, in a bare
     `fn` body, and inside brackets. It is also what the top-level emitter
     has always written, so local and top-level multi-clause functions now
     read the same. Found by test/fuzz. *)
  let lines = List.mapi (fun i (pats, body) ->
    let (annot_s, body) = split_clause_annot body in
    let head =
      let_keyword ^ " " ^ name ^ " "
      ^ String.concat " " (List.map emit_pat_atom pats) ^ annot_s
    in
    (* The first clause starts where the caller left the cursor; the rest
       start their own line at the indent. *)
    let clause_col = if i = 0 then col else indent in
    let oneline = head ^ " = " ^ emit_expr indent body in
    if fits clause_col oneline then oneline
    else emit_bound_value ~col:clause_col indent head body
  ) clauses in
  String.concat "\n"
    (List.mapi (fun i l -> if i = 0 then l else String.make indent ' ' ^ l) lines)

(* One binding of a block, with no body after it: the `;` that follows is
   the terminator, as a newline is at the top level of a file. *)
(* A binding in a block. Its value is always followed by the block's `;` --
   a block cannot end with a `let`, so there is always something after it --
   which is why a value ending in an arm is bracketed here and not asked
   about. *)
and emit_binding ?col indent p e1 =
  let col = match col with Some c -> c | None -> indent in
  (* One column further in inside the bracket, so the arms sit under the
     `match` and not under its `(`. *)
  let arm = ends_in_an_arm e1 in
  let value ind e = if arm then bracket (emit_expr (ind + 1) e) else emit_expr ind e in
  match e1 with
  | Fn (params, fbody) -> emit_fn_clauses ~col indent p params fbody
  | Annot (te, body) ->
    "let " ^ emit_pat p ^ " : " ^ emit_type_expr te ^ " = " ^ value indent body
  | _ when is_multiline_raw_string e1 ->
    (* Cuddled here as at the top level. A block binding gives every other
       wrapped value a line of its own, and that is the shape the corpus is
       written in -- but a line of its own is exactly what this one cannot
       have without indenting text that is content. *)
    let head = "let " ^ emit_pat p ^ " = " in
    head ^ emit_expr ~col:(col + String.length head) indent e1
  | _ ->
    let oneline = "let " ^ emit_pat p ^ " = " ^ value indent e1 in
    if fits col oneline then oneline
    else
      "let " ^ emit_pat p ^ " =\n" ^ String.make (indent + 2) ' '
      ^ (if arm then value (indent + 2) e1
         else bracket_if_wrapped_app e1 (emit_expr (indent + 2) e1))

and emit_let ?col indent p e1 e2 =
  let col = match col with Some c -> c | None -> indent in
  (* A comment between this binding and what reads it: after the value ends
     and before the body begins. It is written above the body, on the lines
     it already occupies. A binding that has one cannot be written on a
     single line. *)
  let ind0 = String.make indent ' ' in
  let after_in =
    match loc_of e1, loc_of e2 with
    | Some a, Some b -> comments_between a.Token.end_offset b.Token.offset
    | _ -> []
  in
  let commented = after_in <> [] in
  let above = String.concat "" (List.map (fun c -> ind0 ^ c.c_text ^ "\n") after_in) in
  match e1 with
  | Fn (params, fbody) ->
    (* A *raw* (non-`Located`) `Fn` as a `let` RHS only ever comes from the
       shorthand `let name params = body` parse (parser.ml:705) -- the one
       form the typechecker treats as recursive (typechecker.ml:658-659,
       matches literal `Fn _`, not `Located (_, Fn _)`). Reprinting it as
       `let name = fn params -> body` would silently make it non-recursive,
       so it must always come back out as shorthand syntax, single-clause or
       multi-equation alike. *)
    (* The first clause carries the keyword and fixes the column its name
       starts at; the rest are that name again, under it. The `in` closes
       the group from the keyword's own column, so the block reads as one
       shape rather than a stack of unrelated lines. *)
    let ind = String.make indent ' ' in
    let tail = bracket_if_wrapped_app e2 (emit_expr indent e2) in
    (* `in ` opens the tail three columns right of the keyword below it, but
       a `let ... in` chain lays its own continuation out at the indent it
       was handed. So a value that wrapped, and the `and` line under it,
       landed left of the `let` they belong to, where the parser reads them
       as something new and the file no longer parses. A chain of more than
       one line takes the whole line, as it does after a value binding's
       `in` and after a commented one. Found by test/fuzz. *)
    let tail_on_its_own_line =
      String.contains tail '\n'
      && (match strip_located e2 with
          | Let (_, _, _, LetIn) | LetRec (_, _, LetIn) -> true
          | _ -> false)
    in
    emit_fn_clauses ~col indent p params fbody
    ^ "\n" ^ ind
    ^ (if commented || tail_on_its_own_line then "in\n" ^ above ^ ind ^ tail
       else "in " ^ tail)
  | Annot (te, body) ->
    (* Reprinting an `Annot`'d let RHS via inline `expr : Type` syntax would
       be genuinely ambiguous: the parser's infix `:` in expression position
       always means cons (list prepend), never ascription, so
       `let x = e : T in ...` re-parses as "cons e onto T", not "e annotated
       with type T". Must go back out through the dedicated
       `let name : T = e` syntax (parser.ml:707-717) instead. *)
    let name = emit_pat p in
    (* The annotated value needs the same brackets the unannotated one gets
       from `emit_bound_value`: a call that wrapped ends at its first line,
       and here the `in` below it is read as continuing the definition
       rather than closing it. This branch went around that helper and so
       around the guard. Found by test/fuzz. *)
    let bodys =
      let emitted = emit_expr indent body in
      bracket_if_wrapped_app body emitted
    in
    let e2s = bracket_if_wrapped_app e2 (emit_expr indent e2) in
    let head = "let " ^ name ^ " : " ^ emit_type_expr te in
    let oneline = head ^ " = " ^ bodys ^ " in " ^ e2s in
    if (not commented) && fits col oneline then oneline
    else
      let ind = String.make indent ' ' in
      Printf.sprintf "%s = %s in\n%s%s%s" head bodys above ind e2s
  | _ ->
  let e1s = emit_expr indent e1 in
  (* A wrapped application after `in` needs its brackets for the same reason
     one after `=` does: it ends where its first line ends, and the argument
     below reads as continuing the definition this `let` belongs to. *)
  let e2s = bracket_if_wrapped_app e2 (emit_expr indent e2) in
  let oneline = Printf.sprintf "let %s = %s in %s" (emit_pat p) e1s e2s in
  let ind = String.make indent ' ' in
  if (not commented) && fits col oneline then oneline
  else
    (* Splitting after `in` is the first thing to try, but the binding alone
       may still be too long -- and the value was rendered as though it began
       at the margin, not after `let name = `. Given its own line it gets the
       room the measurement assumed, and wraps on its own terms. *)
    let bound = Printf.sprintf "let %s = %s in" (emit_pat p) e1s in
    if fits col bound then
      (* A bracketed tail after `in` opens on the same line, brace-style,
         like a bracketed value after `=`. *)
      (if opens_a_bracket e2 && not commented then
         bound ^ " " ^ emit_expr ~col:(col + String.length bound + 1) indent e2
       else bound ^ "\n" ^ above ^ ind ^ e2s)
    else
      emit_bound_value ~col indent ("let " ^ emit_pat p) e1
      ^ "\n" ^ ind ^ "in\n" ^ above ^ ind ^ e2s

(* The `let f ... and g ...` group on its own, without whatever reads it:
   the `in` form puts its body below, the block form puts a `;`. *)
and emit_letrec_bindings indent bindings =
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
  String.concat ("\n" ^ ind) lines

and emit_letrec indent bindings e2 =
  let ind = String.make indent ' ' in
  emit_letrec_bindings indent bindings ^ "\n" ^ ind ^ "in "
  ^ bracket_if_wrapped_app e2 (emit_expr indent e2)

and emit_if ?col indent c t el =
  let col = match col with Some c -> c | None -> indent in
  (* The condition gets the same treatment the branches get, and did not.
     `then` has to follow it, and an application that wrapped is over by the
     time the next line starts -- so the parser arrives at the argument
     below still owed a `then`. Found by test/fuzz. *)
  let cs = bracket_if_wrapped_app c (emit_expr indent c)
  and ts = emit_expr indent t in
  (* A branch that does nothing is written by leaving it out, so `else ()` --
     however it was written -- comes back as the one-armed form. *)
  match strip_located el with
  | Unit ->
    let oneline = Printf.sprintf "if %s then %s" cs ts in
    if fits col oneline then oneline
    else
      Printf.sprintf "if %s then\n%s%s" cs (String.make (indent + 2) ' ')
        (bracket_if_wrapped_app t ts)
  | _ ->
    let es = emit_expr indent el in
    let oneline = Printf.sprintf "if %s then %s else %s" cs ts es in
    if fits col oneline then oneline
    else
      (* An `if` that starts mid-line -- after `x = ` or `fn a -> ` -- owns
         none of the text to its left, so its `else` steps in rather than
         landing flush with the line that introduced it. An else-if chain
         is one ladder: every clause lands at that same indent, instead of
         each else stepping past the one before it. *)
      let cont = if col > indent then indent + 2 else indent in
      let ind = String.make cont ' ' in
      (* A branch that wrapped ends at its first line, so what is left of it
         below reads as continuing whatever the `if` belongs to. *)
      let rec ladder c t el =
        let clause =
          Printf.sprintf "if %s then %s"
            (bracket_if_wrapped_app c (emit_expr cont c))
            (bracket_if_wrapped_app t (emit_expr cont t)) in
        match strip_located el with
        | Unit -> [clause]
        | If (c2, t2, el2) -> clause :: ladder c2 t2 el2
        | _ ->
          [clause;
           bracket_if_wrapped_app el (emit_expr ~col:(cont + 5) cont el)]
      in
      String.concat ("\n" ^ ind ^ "else ") (ladder c t el)

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
   to find what actually ends up printed last.

   Every form below prints its tail unguarded, and each one hid the same
   bug. `with r as _ -> match ...` as an arm body silently gave its `|`
   arms away to the nested match, and the arm above lost them -- a
   different program, printed as a fixed point, so a check that only asks
   whether formatting settles could not see it. Found by the daily fuzzer
   under a `handle`, where the reparse also respelled a pattern and made
   the output finally disagree with itself (#22).

   An `if` with no `else` carries a bare `Unit` the parser wrote, and its
   *then* branch is what prints last. One that was written carries a
   location, so it does not match here. *)
and case_body_tail e = match strip_located e with
  | Let (_, _, e2, _)     -> case_body_tail e2
  | LetRec (_, e2, _)     -> case_body_tail e2
  | With (_, _, body)     -> case_body_tail body
  | Fn (_, body)          -> case_body_tail body
  | If (_, then_, Unit)   -> case_body_tail then_
  | If (_, _, els)        -> case_body_tail els
  | e -> e

and emit_case_body ?col indent body =
  match case_body_tail body with
  | Match _ | Handle _ ->
    (* The parentheses are load-bearing (a bare nested match would swallow
       the outer arms), so give them the same block shape a multi-line Seq
       gets: open the block on the arrow's line, the nested match two
       deeper, the closing paren back at the arm's indent -- rather than a
       nested match whose arms sit flush with the outer ones. *)
    let ind = String.make indent ' ' in
    let inner = String.make (indent + 2) ' ' in
    "(\n" ^ inner ^ emit_expr (indent + 2) body ^ "\n" ^ ind ^ ")"
  (* An application wide enough to wrap needs its parentheses back here for
     the same reason a binding's does: it ends where its first line does,
     and the argument left below is read as continuing the definition the
     whole match belongs to. Without them the formatter turned a working
     file into one that does not parse. *)
  | _ ->
    let flat = emit_expr ?col indent body in
    (* A `let ... in` body that does not fit on the arrow's line put its
       continuation at the arm's own indent, level with the `|` above it,
       where it read as the next statement rather than the rest of this
       arm. It takes the block shape a nested match takes, for the reason
       a nested match takes it. *)
    let is_let_in = match strip_located body with
      | Let (_, _, _, LetIn) | LetRec (_, _, LetIn) -> true
      | _ -> false
    in
    if is_let_in && String.contains flat '\n' then begin
      let ind = String.make indent ' ' in
      let inner = String.make (indent + 2) ' ' in
      "(\n" ^ inner ^ emit_expr (indent + 2) body ^ "\n" ^ ind ^ ")"
    end else bracket_if_wrapped_app body flat

(* The scrutinee shares its own "with" keyword with any enclosing match's
   "with", so an unparenthesized nested Match there is fragile even when
   it happens to parse back correctly -- always wrap for clarity/safety. *)
and emit_scrutinee indent scr =
  match strip_located scr with
  | Match _ -> bracket (emit_expr indent scr)
  (* `with` has to follow the scrutinee, and an application that wrapped has
     already ended by the time the next line starts -- the parser reaches the
     argument below expecting the keyword. *)
  | _ -> bracket_if_wrapped_app scr (emit_expr indent scr)

and emit_match ?col indent scr cases =
  let col = match col with Some c -> c | None -> indent in
  (* Arms of a `match` that starts mid-line step in, as an `if`'s else
     does, instead of landing flush with the line that introduced it. *)
  let arm_indent = if col > indent then indent + 2 else indent in
  let ind = String.make arm_indent ' ' in
  (* Where the arm before this one ended. A comment after that point and
     before this arm's own start belongs above this arm; one before it sits
     inside the previous arm and is that arm's to write. *)
  let prev_end = ref (match loc_of scr with Some l -> l.Token.end_offset | None -> max_int) in
  let emit_case (p, guard, body) =
    (* The arm itself has no location, so its start is taken from the first
       located part of it -- the guard when there is one, otherwise the
       body. Both begin after the `|`, which only widens the window
       leftward into the arrow and pattern, where no comment can sit
       without ending the line. *)
    let lead =
      match loc_of (match guard with Some g -> g | None -> body) with
      | None -> []
      | Some l ->
        List.map (fun c -> ind ^ c.c_text ^ "\n")
          (comments_between !prev_end l.Token.offset)
    in
    (match loc_of body with
     | Some l -> prev_end := l.Token.end_offset
     | None -> prev_end := max_int);
    let guard_s = match guard with
      | None -> ""
      | Some g -> " when " ^ emit_expr arm_indent g
    in
    (* The body starts after the pattern and the arrow, not at the case's
       indent -- which is the whole of this bug. *)
    let prefix = ind ^ "| " ^ emit_pat p ^ guard_s ^ " -> " in
    let text = prefix ^ emit_case_body ~col:(String.length prefix) arm_indent body in
    String.concat "" lead ^ text
  in
  "match " ^ emit_scrutinee indent scr ^ " with\n"
  ^ String.concat "\n" (List.map emit_case cases)

(* The value after an `=`, once it is known not to fit on one line. It stays
   on the `=` line only when it carries the break itself and still needs
   more than one line. Otherwise it takes the next line, and an application
   that wrapped there gets its parentheses. *)
and emit_bound_value ~col indent head body =
  let below = "\n" ^ String.make (indent + 2) ' ' in
  let cuddled () = emit_expr ~col:(col + String.length head + 3) indent body in
  (* The value's own bracket goes here whatever it costs: given a line of
     its own it says nothing, since the items sit at the same column either
     way. *)
  if opens_a_bracket body then head ^ " = " ^ cuddled ()
  else
    let indented = emit_expr (indent + 2) body in
    (* A call is not its bracket, so the choice is open. Its own line is
       what it was denied, and the room may be all it needed -- one line
       under the head beats a bracket opened here and closed three lines
       down. *)
    if not (String.contains indented '\n') then head ^ " =" ^ below ^ indented
    else if not (carries_the_break body) then
      head ^ " =" ^ below ^ bracket_if_wrapped_app body indented
    else
      (* The shape says the call ends in a bracket; this says the bracket is
         still open where the first line ends, which is the whole reason the
         value may start here. A short one stays on that line and closes
         it, and then the definition would end there.

         `carries_the_break` is asked first because it reads the shape and
         costs nothing, while `cuddled ()` lays the whole value out again. *)
      let c = cuddled () in
      if depth_after_first_line c > 0 then head ^ " = " ^ c
      else head ^ " =" ^ below ^ bracket_if_wrapped_app body indented

let emit_one_equation head_kw pats body =
  let (annot_s, body) = split_clause_annot body in
  let head = head_kw ^ " " ^ String.concat " " (List.map emit_pat_atom pats) ^ annot_s in
  let oneline = head ^ " = " ^ emit_expr 0 body in
  if fits 0 oneline then oneline
  else emit_bound_value ~col:0 0 head body

(* ── Type definitions ─────────────────────────────────────────────────────── *)

(* A named field's type may be an application -- `children: List Node` -- and
   is written without parentheses, since the comma or the closing paren ends
   it. A positional field may not: `Pair Int Int` is two fields, not one
   applied to the other, so those stay atoms. An arrow needs its parentheses
   either way, and `emit_type_app_expr` still adds them. *)
let emit_named_field_type t = emit_type_app_expr t

(* `= value` where the field declares a default. Only a named field can carry
   one, so this never reaches the positional form. *)
let emit_field_default defaults n =
  match List.assoc_opt n defaults with
  | Some d -> " = " ^ emit_expr 0 d
  | None -> ""

let emit_ctor_fields ?(defaults = []) fields =
  if fields = [] then ""
  else match fields with
    | (Some _, _) :: _ ->
      "(" ^ String.concat ", " (List.map (fun (n, t) ->
        let n = Option.get n in
        n ^ ": " ^ emit_named_field_type t ^ emit_field_default defaults n)
        fields) ^ ")"
    | _ ->
      " " ^ String.concat " " (List.map (fun (_, t) -> emit_type_atom t) fields)

(* Named fields, one per line, for a constructor too wide to fit. Positional
   fields are left alone: they are type atoms, so a long positional
   constructor is long because its types are, and breaking it up does not
   help. *)
let emit_ctor_fields_wrapped ?(defaults = []) name fields =
  match fields with
  | (Some _, _) :: _ ->
    name ^ "(\n"
    ^ String.concat ",\n"
        (List.map (fun (n, t) ->
           let n = Option.get n in
           "  " ^ n ^ ": " ^ emit_named_field_type t
           ^ emit_field_default defaults n) fields)
    ^ "\n)"
  | _ -> name ^ emit_ctor_fields fields

let emit_type_def = function
  | Alias (name, params, te) ->
    let name_and_params =
      name
      ^ (if params = [] then ""
         else " " ^ String.concat " " (List.map (fun p -> "'" ^ p) params))
    in
    "type " ^ name_and_params ^ " = " ^ emit_type_expr te
  | Variants (name, params, ctors) ->
  let name_and_params =
    name
    ^ (if params = [] then "" else " " ^ String.concat " " (List.map (fun p -> "'" ^ p) params))
  in
  match ctors with
  (* The parser reads `type Foo(fields)` as `type Foo = Foo(fields)`;
     when the one constructor is the type saying its own name again, the
     shorthand is the canonical form. Named fields only: a positional
     payload prints without the parentheses the shorthand needs to
     re-parse. *)
  | [c] when c.name = name
          && (match c.fields with (Some _, _) :: _ -> true | _ -> false) ->
    let oneline =
      "type " ^ name_and_params
      ^ emit_ctor_fields ~defaults:c.defaults c.fields in
    if fits 0 oneline then oneline
    else "type "
         ^ emit_ctor_fields_wrapped ~defaults:c.defaults name_and_params c.fields
  | _ ->
  let head = "type " ^ name_and_params ^ " = " in
  let oneline =
    head ^ String.concat " | "
      (List.map (fun c ->
         c.name ^ emit_ctor_fields ~defaults:c.defaults c.fields) ctors)
  in
  if fits 0 oneline then oneline
  else match ctors with
    (* A single constructor with named fields is a record: widen it down the
       page rather than past the margin. Several constructors wrap at the
       alternatives instead, which is where a reader looks first. *)
    | [c] -> head ^ emit_ctor_fields_wrapped ~defaults:c.defaults c.name c.fields
    | _ ->
      head ^ "\n  "
      ^ String.concat "\n  | "
          (List.map (fun c ->
             c.name ^ emit_ctor_fields ~defaults:c.defaults c.fields) ctors)

(* ── Top-level items ──────────────────────────────────────────────────────── *)

(* One item's layouts belong to that item. `interior` and `item_start` are
   set around this call and read while it runs, so a layout produced under
   one item's comments must not be handed to the next. *)
let emit_top_item_pretty_uncached = function
  | TLImport (StdlibModule n) -> "import " ^ n
  | TLImport (UserPath p)     -> "import " ^ p
  | TLType (tdef, _) -> emit_type_def tdef
  | TLLetPat (p, e) ->
    let body = emit_expr 0 e in
    let oneline = Printf.sprintf "let %s = %s" (emit_pat_binder p) body in
    if fits 0 oneline then oneline
    else
      Printf.sprintf "let %s =\n  %s" (emit_pat_binder p)
        (bracket_if_wrapped_app e (emit_expr 2 e))
  | TLLet (name, [], Annot (te, body)) ->
    (* Same ambiguity as the local-`let` case: reprinting via inline
       `expr : Type` would re-parse as cons, not ascription -- keep the
       dedicated `let name : T = e` syntax. *)
    let bodys = emit_expr 0 body in
    let head = "let " ^ name ^ " : " ^ emit_type_expr te in
    let oneline = head ^ " = " ^ bodys in
    if fits 0 oneline then oneline
    else emit_bound_value ~col:0 0 head body
  | TLLet (name, [], e) ->
    with_body_lead ("let " ^ name) 0 e (fun () ->
      let body = emit_expr 0 e in
      let oneline = Printf.sprintf "let %s = %s" name body in
      if fits 0 oneline then oneline
      else emit_bound_value ~col:0 0 ("let " ^ name) e)
  | TLLet (name, params, e) ->
    (match try_multi_equation params e with
     | Some clauses ->
       String.concat "\n" (List.map (fun (pats, body) ->
         emit_one_equation ("let " ^ name) pats body) clauses)
     | None ->
       let lead = body_lead e in
       let (annot_s, e) = split_clause_annot e in
       let head = "let " ^ name ^ " " ^ String.concat " " (List.map emit_pat_atom params) ^ annot_s in
       (match lead with
        | [] ->
          let oneline = head ^ " = " ^ emit_expr 0 e in
          if fits 0 oneline then oneline
          else emit_bound_value ~col:0 0 head e
        | cs ->
          head ^ " =\n"
          ^ String.concat "" (List.map (fun c -> "  " ^ c.c_text ^ "\n") cs)
          ^ "  " ^ emit_expr 2 e))
  | TLLetRec bindings ->
    let emit_binding kw (name, params, body) =
      let (annot_s, body) = split_clause_annot body in
      let head = kw ^ " " ^ name
        ^ (if params = [] then "" else " " ^ String.concat " " (List.map emit_pat_atom params))
        ^ annot_s in
      let oneline = head ^ " = " ^ emit_expr 0 body in
      if fits 0 oneline then oneline
      else emit_bound_value ~col:0 0 head body
    in
    (match bindings with
     | [] -> ""
     | first :: rest ->
       String.concat "\n" (emit_binding "let" first :: List.map (emit_binding "and") rest))
  | TLExpr e ->
    (* A top-level expression is subject to the same rule as a binding's
       value: wrapped as a bare application it stops being one expression. *)
    let text = bracket_if_wrapped_app e (emit_expr 0 e) in
    (* And to one more. A line that opens with an operator continues the
       line above it -- that is how a pipeline is written, and the reference
       warns that `-` surprises people the same way. An item of its own that
       opens with one is read as more of the item before it, so `-1` under a
       definition becomes a subtraction. Brackets say it is its own
       statement. Found by test/fuzz. *)
    let continues_the_line_above =
      text <> ""
      && (match text.[0] with
          | '-' | '+' | '*' | '/' | '<' | '>' | '=' | '&' | '|' | ':' -> true
          | _ -> false)
    in
    if continues_the_line_above then bracket text else text

(* One item's layouts belong to that item. `interior` and `item_start` are
   set around this call and read while it runs, so a layout produced under
   one item's comments must not be handed to the next. *)
let emit_top_item_pretty item =
  Layouts.reset layouts;
  emit_top_item_pretty_uncached item

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
  (* A blank line after this piece whether or not the source had one. Only
     the manifest sets it: it is a statement about the whole file rather
     than a line of it, and every file that carries one stands it off from
     the code. Left to the source, a manifest `wand t --fix` had just
     inserted stayed jammed against the first import, and no amount of
     `wand f` would separate them. *)
  blank_after : bool;
}

(* Trim trailing whitespace/newlines only -- leading indentation and
   interior formatting are preserved exactly (verbatim rendering). *)
(* For each item, decide its rendered text and its [start_offset, stop)
   span. An item falls back to an exact verbatim source slice only when a
   comment sits inside its own span (multi-equation clauses, or a comment
   inside a function body): pretty-printing would otherwise have to either
   drop that comment or relocate it outside the item, so the safe fallback
   is to leave the whole item exactly as written. *)
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
    let mine =
      List.filter (fun c -> c.c_offset > start_loc.offset && c.c_offset < end_loc.offset)
        comments
    in
    (* An interior comment is offered to the emitters, which write it above
       whichever arm or statement it sits on.

       What comes back is then checked against what went in, by counting
       each comment's text in the rendered item. The emitters render drafts
       and discard them, and a construct can be reached by more than one
       path, so a comment can go missing or be written twice -- and neither
       may reach a file. Anything but exactly once sends the item back to a
       verbatim slice, which is what every item with an interior comment
       used to be. *)
    (* Counted by lexing the rendering, not by searching its text. A
       comment's characters can appear in the output without being a
       comment: a rendering that had dropped the comment `--` still held a
       string `"--"`, the search found its two characters, and the item was
       accepted with the comment gone. Lexing asks the question that was
       meant. Trailing whitespace comes off both sides, because removing it
       is the formatter doing its job. Found by test/fuzz. *)
    let rendered_comments text =
      match all_comments text (Lexer.tokenize text) with
      | cs -> Some (List.map (fun c -> rstrip_ws c.c_text) cs)
      | exception _ -> None
    in
    let attempt =
      if mine = [] then Some (emit_top_item_pretty item)
      else begin
        interior := List.sort (fun a b -> compare a.c_offset b.c_offset) mine;
        item_start := start_loc.offset;
        (* Cleared however this ends. `emit_top_item_pretty` can raise, and
           these two are module-level: left set, they would be read by
           whatever the next call to `format_source` formats, in this process
           or any other that keeps one alive -- the language server does.
           Found by test/fuzz, which noticed findings that reproduced in the
           loop and not in a process of their own. *)
        let text =
          Fun.protect ~finally:(fun () -> interior := []; item_start := 0)
            (fun () -> emit_top_item_pretty item)
        in
        let ok =
          (* A rendering that will not lex cannot be checked, so it is not
             trusted: the item goes back to a verbatim slice. *)
          match rendered_comments text with
          | None -> false
          | Some got ->
            List.for_all (fun c ->
              let want = rstrip_ws c.c_text in
              let wanted =
                List.length (List.filter (fun d -> rstrip_ws d.c_text = want) mine) in
              List.length (List.filter (( = ) want) got) = wanted) mine
        in
        if ok then Some text else None
      end
    in
    let is_verbatim = attempt = None in
    let text =
      match attempt with
      | Some t -> t
      | None -> rstrip_ws (String.sub src start_loc.offset (stop - start_loc.offset))
    in
    (* A verbatim slice runs to the next item's offset, so it absorbs any
       comment sitting between the two. Its text therefore ends later than
       the AST's end_loc says, and trusting that would leave an apparent gap
       for `assemble` to fill with a blank line -- separating a doc comment
       from the binding it documents. Count the lines actually emitted. *)
    (* `end_loc.end_line`, not `end_loc.line`: the two differ when the item's
       last token spans lines of its own -- a raw string with a newline in it
       is the case that arises -- and `line` is where that token *started*.
       Reading it as the item's last line left an apparent gap for `assemble`
       to fill, so `wand f` inserted a blank line the second time it ran over
       its own output. Found by test/fuzz. *)
    let end_line =
      if is_verbatim then
        start_loc.line + List.length (String.split_on_char '\n' text) - 1
      else end_loc.Token.end_line
    in
    let piece = { offset = start_loc.offset; start_line = start_loc.line;
                  end_line; text; is_comment = false; blank_after = false } in
    (* What the item's own text now accounts for. A verbatim slice runs to
       the next item and absorbs the comments between the two; a
       pretty-printed item ends where the item ends, so a comment below it
       is still a piece of its own. *)
    let consumed =
      if mine = [] then None
      else if is_verbatim then Some (start_loc.offset, stop)
      else Some (start_loc.offset, end_loc.Token.offset)
    in
    (is_verbatim, consumed, start_loc.offset, stop, piece))

(* A piece that opens with an operator continues the piece above it, which
   is the hazard `emit_top_item_pretty_uncached` brackets a `TLExpr` for. An
   item that fell back to a verbatim slice never reached that guard, and
   cannot use it either: the slice holds the comment that sent it there, so
   brackets around it would enclose a comment and whatever else the item
   spans.

   The separator is what it had. Such an item was written after a `;` on the
   line above -- that is how it parsed as an item of its own rather than as
   more of the item before it -- and the slice starts at the item, so the
   `;` was dropped and a newline put in its place. Writing the `;` back is
   the smaller claim: it restores the boundary the source stated, rather
   than inventing brackets. `let b = import /p; -` re-read as
   `let b = import /p - ...` without it, which moved the `import` inside a
   binary expression. Found by test/fuzz. *)
(* Whether a piece's text ends inside a comment. A comment runs to the end
   of its line and swallows whatever is written after it, so a separator put
   there stops being a separator and changes the comment's own text instead.

   `prev_is_comment` answers this for a piece that *is* a comment. It cannot
   answer it for a verbatim slice, which runs to the next item and so ends in
   whatever the source had there -- a trailing comment among the rest. Asked
   by lexing, because `--` inside a string is not a comment. Found by
   test/fuzz. *)
let ends_in_a_comment text =
  match Lexer.tokenize text with
  | tokens ->
    (* Past the `Newline` and `EOF` the lexer ends every list with: they say
       nothing about what the last line holds. *)
    let rec last = function
      | (Token.Newline, _) :: tl | (Token.EOF, _) :: tl -> last tl
      | (Token.LineComment _, _) :: _ -> true
      | _ -> false
    in
    last (List.rev tokens)
  | exception _ -> false

let opens_with_an_operator text =
  text <> ""
  && (match text.[0] with
      | '-' | '+' | '*' | '/' | '<' | '>' | '=' | '&' | '|' | ':' -> true
      | _ -> false)

let assemble pieces =
  (* Source order, not line order: an item and a comment can start on the
     same line, and which came first decides whether the comment trails the
     item or introduces it. *)
  let sorted = List.sort (fun a b -> compare a.offset b.offset) pieces in
  let buf = Buffer.create 1024 in
  let prev_end = ref None in
  let prev_blank_after = ref false in
  let prev_is_comment = ref false in
  let prev_text = ref None in
  List.iter (fun p ->
    (match !prev_end with
     | None -> ()
     | Some pel ->
       if p.is_comment && p.start_line = pel then
         Buffer.add_string buf "  "
       else begin
         (* The separator goes on the piece above, so there has to be one
            that can hold it. A comment runs to the end of its line and
            swallows whatever is written after it: the `;` became part of
            the comment, the operator line still opened a line of its own,
            and the next pass wrote another one -- `--` grew a `;` per pass,
            for ever, and the comment's own text changed under it.

            Nothing is owed above a comment anyway. A comment ends the line
            it is on, so the operator below it is not continuing anything.
            Found by test/fuzz, on eight seeds at once. *)
         (* A verbatim slice runs to the next item's offset, so it already
            holds the `;` that ended the item above it. Writing a second one
            grew the line by a `;` per pass, for ever. Ask what the piece
            above ends with rather than what kind of piece it is: a
            pretty-printed item never ends in `;`, so this only ever
            declines to repeat a separator that is already there. Found by
            test/fuzz. *)
         let already_separated =
           match !prev_text with
           | Some t -> t <> "" && t.[String.length t - 1] = ';'
           | None -> false
         in
         (* `ends_in_a_comment` lexes, so it is asked last: only a piece
            that opens with an operator can reach it. *)
         if (not p.is_comment) && (not !prev_is_comment)
            && (not already_separated)
            && opens_with_an_operator p.text
            && not (match !prev_text with
                    | Some t -> ends_in_a_comment t
                    | None -> false) then
           Buffer.add_char buf ';';
         Buffer.add_char buf '\n';
         if !prev_blank_after || p.start_line - pel - 1 > 0 then
           Buffer.add_char buf '\n'
       end);
    Buffer.add_string buf p.text;
    prev_end := Some p.end_line;
    prev_blank_after := p.blank_after;
    prev_is_comment := p.is_comment;
    prev_text := Some p.text
  ) sorted;
  if Buffer.length buf > 0 then Buffer.add_char buf '\n';
  Buffer.contents buf

(* The `#!` line, which the lexer steps over and emits no token for. So it
   reaches neither the parser nor the pieces, and a file assembled from
   pieces alone came back without it -- `wand f` writes in place, so
   formatting a script that runs itself stopped it running. The reference
   documents the form, and nothing was keeping it. *)
let shebang_of src =
  if String.length src >= 2 && src.[0] = '#' && src.[1] = '!' then
    match String.index_opt src '\n' with
    | Some i -> Some (String.sub src 0 i)
    | None -> Some src
  else None

let format_source src =
  let tokens = Lexer.tokenize src in
  let (prog, item_locs) = Parser.parse_program_with_locs tokens in
  let comments = all_comments src tokens in
  let items = item_pieces src prog item_locs comments in
  (* Every item that held an interior comment, verbatim or not: in both
     cases the comment is already inside the item's own text, so it must not
     be laid out a second time as a piece of its own. *)
  let consumed_spans = List.filter_map (fun (_, c, _, _, _) -> c) items in
  let in_any_span off = List.exists (fun (s, e) -> off > s && off < e) consumed_spans in
  let comment_pcs = List.filter_map (fun c ->
    if in_any_span c.c_offset then None
    else Some { offset = c.c_offset; start_line = c.c_start_line;
                end_line = c.c_end_line; text = c.c_text; is_comment = true;
                blank_after = false }
  ) comments in
  let item_pcs = List.map (fun (_, _, _, _, p) -> p) items in
  (* The leading import region -- the run of imports before the first item
     of anything else -- is grouped: plain `import M` first, alphabetized,
     then let-imports in source order. Plain imports may be sorted because
     each binds only its own namespace name; let-imports are ordinary
     bindings whose rebinding order is program meaning, so they are never
     reordered among themselves, only hoisted below the plain block (an
     import's right-hand side depends on nothing file-local). A region with
     a comment in it is left as written: sorting would move lines out from
     under the comment that explains them. *)
  let items_arr = Array.of_list prog.Ast.items in
  let kind i =
    if i >= Array.length items_arr then None
    else match items_arr.(i) with
      | Ast.TLImport _ -> Some `Plain
      | Ast.TLLet (_, [], body) when Module_types.import_kind_of body <> None ->
        Some `Let
      | Ast.TLLetPat (_, body) when Module_types.import_kind_of body <> None ->
        Some `Let
      | _ -> None
  in
  let rec region_len i = if kind i = None then i else region_len (i + 1) in
  let k = region_len 0 in
  let item_pcs =
    if k < 2 then item_pcs
    else begin
      let region = List.filteri (fun i _ -> i < k) items in
      let region_start = match region with (_, _, s, _, _) :: _ -> s | [] -> 0 in
      let region_stop =
        List.fold_left (fun _ (_, _, _, stop, _) -> stop) region_start region in
      let untouchable =
        List.exists (fun (v, _, _, _, _) -> v) region
        || List.exists (fun c ->
             c.c_offset >= region_start && c.c_offset < region_stop) comments
      in
      if untouchable then item_pcs
      else begin
        let texts_of which =
          List.filteri (fun i _ -> i < k) item_pcs
          |> List.mapi (fun i p -> (kind i, p.text))
          |> List.filter_map (fun (ki, t) -> if ki = Some which then Some t else None)
        in
        let ordered =
          List.sort compare (texts_of `Plain) @ texts_of `Let in
        List.mapi (fun i p ->
          if i < k then { p with text = List.nth ordered i } else p) item_pcs
      end
    end
  in
  (* The block of plain imports stands off from whatever follows it -- the
     destructured imports under it, or the first definition. Every file that
     has an import block already reads that way; left to the source, one
     written without the blank line kept it. Only the leading region counts:
     an import further down the file is where its author put it, and is not
     the top of anything. *)
  let item_pcs =
    let is_plain_import p =
      (not p.is_comment)
      && String.length p.text >= 7
      && String.sub p.text 0 7 = "import "
    in
    (* Found by emitted text rather than by original position: the region may
       have just been sorted, which moves the plain imports to the front of
       it, so where the last one started out says nothing about where it
       ends up. *)
    let last_plain =
      snd (List.fold_left
             (fun (i, best) p ->
                (i + 1, if i < k && is_plain_import p then Some i else best))
             (0, None) item_pcs)
    in
    match last_plain with
    | None -> item_pcs
    | Some li ->
      List.mapi (fun i p -> if i = li then { p with blank_after = true } else p)
        item_pcs
  in
  (* A manifest is not a top-level item -- it is held apart on the program,
     since it is a property of the file rather than something in it -- so it
     has to be emitted here or the formatter would silently drop it, turning
     a bounded file into an unbounded one. Emission is canonical: labels in
     display order (alphabetical, one definition with the typechecker's
     suggestions), the binaries inside Shell(...) sorted, and the whole
     form wrapping like any bracketed form when it passes the column
     budget -- the newlines sit inside braces, so a wrapped manifest
     already parses. *)
  let manifest_pcs =
    match prog.Ast.manifest with
    | None -> []
    | Some (labels, loc) ->
      let labels =
        List.map (fun (n, allow) -> (n, Option.map (List.sort compare) allow))
          labels
        |> List.sort (fun (a, _) (b, _) -> compare a b)
      in
      let one_line =
        "uses {" ^ String.concat ", " (List.map Shell_scan.render_label labels)
        ^ "}"
      in
      let text =
        if String.length one_line <= !max_width then one_line
        else
          let label_text (n, allow) =
            let r = Shell_scan.render_label (n, allow) in
            match allow with
            | Some args when String.length r + 2 > !max_width ->
              "  " ^ n ^ "(\n"
              ^ String.concat ",\n"
                  (List.map (fun a -> "    " ^ Shell_scan.render_entry a) args)
              ^ "\n  )"
            | _ -> "  " ^ r
          in
          "uses {\n" ^ String.concat ",\n" (List.map label_text labels) ^ "\n}"
      in
      [{ offset     = loc.Token.offset;
         start_line = loc.Token.line;
         end_line   = loc.Token.end_line;
         text;
         is_comment = false;
         blank_after = true }]
  in
  let body = assemble (manifest_pcs @ comment_pcs @ item_pcs) in
  match shebang_of src with
  | None -> body
  | Some line -> line ^ "\n" ^ body
