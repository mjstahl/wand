open Token

exception LexError of string

type state = {
  src  : string;
  mutable pos  : int;
  mutable line : int;
  mutable col  : int;
}

let make src = { src; pos = 0; line = 1; col = 1 }

let len s = String.length s.src
let is_at_end s = s.pos >= len s
let peek s  = if s.pos     >= len s then '\000' else s.src.[s.pos]
let peek2 s = if s.pos + 1 >= len s then '\000' else s.src.[s.pos + 1]
let char_at s offset =
  let i = s.pos + offset in
  if i >= len s then '\000' else s.src.[i]
let advance s =
  let c = peek s in
  s.pos <- s.pos + 1;
  (if c = '\n' then (s.line <- s.line + 1; s.col <- 1)
   else s.col <- s.col + 1);
  c

let is_digit c = c >= '0' && c <= '9'
let is_lower c = c >= 'a' && c <= 'z'
let is_upper c = c >= 'A' && c <= 'Z'
let is_alpha c = is_lower c || is_upper c
let is_alnum_or_under c = is_alpha c || is_digit c || c = '_'
let is_path_body_char c = is_alnum_or_under c || c = '-' || c = '.' || c = '/'
let is_glob_char c = c = '*' || c = '?' || c = '['

(* ── Keywords & identifiers ─────────────────────────────────────────────── *)

let keyword_or_ident word = match word with
  | "let"      -> Let      | "in"       -> In
  | "match"    -> Match    | "with"     -> With
  | "if"       -> If       | "then"     -> Then
  | "else"     -> Else     | "type"     -> Type
  | "token"    -> Token    | "import"   -> Import
  | "requires" -> Requires
  | "ensures"  -> Ensures  | "result"   -> Result
  | "fn"       -> Fn       | "fun"      -> Fn
  | "of"       -> Of
  | "for"      -> For      | "do"       -> Do
  | "end"      -> End      | "class"    -> Class
  | "instance" -> Instance | "orphan"   -> Orphan
  | "when"     -> When     | "and"      -> And
  | "or"       -> Or       | "handle"   -> Handle
  | "return"   -> Return   | "try"      -> Try
  | "true"     -> Bool true
  | "false"    -> Bool false
  | "_"        -> Underscore
  | s when s.[0] >= 'A' && s.[0] <= 'Z' -> Upper s
  | s          -> Ident s

(* ── String literals ────────────────────────────────────────────────────── *)

let read_string s =
  let parts = ref [] in
  let buf = Buffer.create 16 in
  let rec loop () =
    if is_at_end s then raise (LexError "unterminated string literal");
    match advance s with
    | '"'  ->
      if !parts = [] then String (Buffer.contents buf)
      else InterpStr (!parts, Buffer.contents buf)
    | '\\' ->
      let c = match advance s with
        | 'n' -> '\n' | 't' -> '\t' | 'r' -> '\r'
        | '\\' -> '\\' | '"' -> '"' | '$' -> '$'
        | c -> raise (LexError (Printf.sprintf "unknown escape \\%c" c))
      in
      Buffer.add_char buf c; loop ()
    | '$' when peek s = '{' ->
      ignore (advance s);
      let lit = Buffer.contents buf in
      Buffer.clear buf;
      let expr_buf = Buffer.create 16 in
      let depth = ref 1 in
      while !depth > 0 do
        if is_at_end s then raise (LexError "unterminated string interpolation");
        let c = advance s in
        if c = '{' then (incr depth; Buffer.add_char expr_buf c)
        else if c = '}' then begin
          decr depth;
          if !depth > 0 then Buffer.add_char expr_buf c
        end else
          Buffer.add_char expr_buf c
      done;
      parts := !parts @ [(lit, Buffer.contents expr_buf)];
      loop ()
    | '$' when is_upper (peek s) ->
      let lit = Buffer.contents buf in
      Buffer.clear buf;
      let name_buf = Buffer.create 8 in
      while not (is_at_end s) && (is_upper (peek s) || is_digit (peek s) || peek s = '_') do
        Buffer.add_char name_buf (advance s)
      done;
      parts := !parts @ [(lit, "$" ^ Buffer.contents name_buf)];
      loop ()
    | c -> Buffer.add_char buf c; loop ()
  in
  loop ()

(* ── Run-command literals: $(cmd ${var}) ────────────────────────────────── *)

let read_run_cmd s =
  let parts = ref [] in
  let buf = Buffer.create 16 in
  let depth = ref 1 in
  let rec loop () =
    if is_at_end s then raise (LexError "unterminated $() command");
    match advance s with
    | '(' ->
      incr depth; Buffer.add_char buf '('; loop ()
    | ')' ->
      decr depth;
      if !depth > 0 then (Buffer.add_char buf ')'; loop ())
      else (* closing paren — done *)
        if !parts = [] then RunCmdRaw ([], Buffer.contents buf)
        else RunCmdRaw (!parts, Buffer.contents buf)
    | '$' when peek s = '{' ->
      ignore (advance s);
      let lit = Buffer.contents buf in
      Buffer.clear buf;
      let expr_buf = Buffer.create 16 in
      let idepth = ref 1 in
      while !idepth > 0 do
        if is_at_end s then raise (LexError "unterminated string interpolation");
        let c = advance s in
        if c = '{' then (incr idepth; Buffer.add_char expr_buf c)
        else if c = '}' then begin
          decr idepth;
          if !idepth > 0 then Buffer.add_char expr_buf c
        end else
          Buffer.add_char expr_buf c
      done;
      parts := !parts @ [(lit, Buffer.contents expr_buf)];
      loop ()
    | '\\' when peek s = '\n' -> ignore (advance s); loop ()
    | c -> Buffer.add_char buf c; loop ()
  in
  loop ()

(* ── Comments ───────────────────────────────────────────────────────────── *)

let read_comment s =
  ignore (advance s);  (* consume '*' after '(' *)
  let is_doc = peek s = '*' && peek2 s <> ')' in
  if is_doc then ignore (advance s);  (* consume second '*' *)
  let buf = if is_doc then Some (Buffer.create 64) else None in
  let depth = ref 1 in
  while !depth > 0 do
    if is_at_end s then raise (LexError "unterminated comment");
    let c = advance s in
    if c = '(' && peek s = '*' then (ignore (advance s); incr depth)
    else if c = '*' && peek s = ')' then begin
      ignore (advance s); decr depth;
      if !depth > 0 then
        Option.iter (fun b -> Buffer.add_char b '*'; Buffer.add_char b ')') buf
    end else
      Option.iter (fun b -> Buffer.add_char b c) buf
  done;
  match buf with
  | None -> None
  | Some b ->
    (* Strip leading/trailing whitespace; strip leading * from each line *)
    let lines = String.split_on_char '\n' (Buffer.contents b) in
    let strip line =
      let s = String.trim line in
      if String.length s > 0 && s.[0] = '*' then String.trim (String.sub s 1 (String.length s - 1))
      else s
    in
    let lines = List.map strip lines in
    (* Drop leading and trailing blank lines *)
    let rec drop_leading = function [] -> [] | "" :: t -> drop_leading t | l -> l in
    let lines = drop_leading lines |> List.rev |> drop_leading |> List.rev in
    Some (String.concat "\n" lines)

(* ── Paths ──────────────────────────────────────────────────────────────── *)

let read_path_body s prefix =
  let buf = Buffer.create 16 in
  Buffer.add_string buf prefix;
  let has_glob = ref (String.exists (fun c -> c = '*' || c = '?' || c = '[') prefix) in
  let rec loop () =
    if not (is_at_end s) then
      let c = peek s in
      if is_path_body_char c then begin
        Buffer.add_char buf (advance s); loop ()
      end else if is_glob_char c then begin
        has_glob := true;
        Buffer.add_char buf (advance s);
        (* consume rest of bracket expression *)
        if c = '[' then begin
          while not (is_at_end s) && peek s <> ']' do
            Buffer.add_char buf (advance s)
          done;
          if not (is_at_end s) then Buffer.add_char buf (advance s)
        end;
        loop ()
      end
  in
  loop ();
  let contents = Buffer.contents buf in
  if !has_glob then Glob contents else Path contents

(* ── URLs ───────────────────────────────────────────────────────────────── *)

let read_url s scheme =
  (* s.pos is at ':' of "://" — consume all three *)
  ignore (advance s); ignore (advance s); ignore (advance s);
  let buf = Buffer.create 32 in
  Buffer.add_string buf scheme;
  Buffer.add_string buf "://";
  while not (is_at_end s)
     && not (List.mem (peek s) [' '; '\t'; '\n'; '\r'; ')'; ']'; '}'; ',']) do
    Buffer.add_char buf (advance s)
  done;
  Url (Buffer.contents buf)

(* ── Size units ─────────────────────────────────────────────────────────── *)

let try_read_size_unit s =
  match peek s with
  | 'K' when peek2 s = 'B' -> ignore (advance s); ignore (advance s); Some "KB"
  | 'M' when peek2 s = 'B' -> ignore (advance s); ignore (advance s); Some "MB"
  | 'G' when peek2 s = 'B' -> ignore (advance s); ignore (advance s); Some "GB"
  | 'T' when peek2 s = 'B' -> ignore (advance s); ignore (advance s); Some "TB"
  | 'P' when peek2 s = 'B' -> ignore (advance s); ignore (advance s); Some "PB"
  | 'B'                     -> ignore (advance s);                     Some "B"
  | _ -> None

(* ── Duration units ─────────────────────────────────────────────────────── *)

let peek3 s = char_at s 2

let try_read_duration_unit s =
  match peek s with
  | 'm' when peek2 s = 's' ->
    ignore (advance s); ignore (advance s); Some "ms"
  | 'm' when peek2 s = 'i' && peek3 s = 'n' ->
    ignore (advance s); ignore (advance s); ignore (advance s); Some "min"
  | 'm' -> ignore (advance s); Some "m"
  | 's' -> ignore (advance s); Some "s"
  | 'h' -> ignore (advance s); Some "h"
  | 'd' -> ignore (advance s); Some "d"
  | 'w' -> ignore (advance s); Some "w"
  | _   -> None

let is_duration_start c = match c with
  | 'm' | 's' | 'h' | 'd' | 'w' -> true
  | _ -> false

let read_duration s first_digits =
  let buf = Buffer.create 16 in
  Buffer.add_string buf first_digits;
  (match try_read_duration_unit s with
   | Some u -> Buffer.add_string buf u
   | None   -> assert false);
  (* Greedily consume additional components like 30m in 1h30m *)
  let continue_ = ref true in
  while !continue_ && not (is_at_end s) && is_digit (peek s) do
    let saved = s.pos in
    let seg = Buffer.create 4 in
    while not (is_at_end s) && is_digit (peek s) do
      Buffer.add_char seg (advance s)
    done;
    (match try_read_duration_unit s with
     | Some u ->
       Buffer.add_string buf (Buffer.contents seg);
       Buffer.add_string buf u
     | None ->
       s.pos <- saved;
       continue_ := false)
  done;
  Duration (Buffer.contents buf)

(* ── Numbers (Int, Float, Date, DateTime, Time, IPv4, CIDR, Version, Size, Duration) *)

let read_numeric s first_char =
  let buf = Buffer.create 8 in
  Buffer.add_char buf first_char;
  while not (is_at_end s) && is_digit (peek s) do
    Buffer.add_char buf (advance s)
  done;
  let first = Buffer.contents buf in

  match peek s with

  (* Dot: Float / IPv4 / CIDR / Version / Size-with-decimal *)
  | '.' when peek2 s <> '.' ->
    ignore (advance s);
    let seg2 = Buffer.create 4 in
    while not (is_at_end s) && is_digit (peek s) do
      Buffer.add_char seg2 (advance s)
    done;
    let s2 = Buffer.contents seg2 in
    if s2 = "" then raise (LexError "expected digits after '.'");
    (match peek s with
     | '.' when peek2 s <> '.' ->
       (* Third segment → Version or IPv4 *)
       ignore (advance s);
       let seg3 = Buffer.create 4 in
       while not (is_at_end s) && is_digit (peek s) do
         Buffer.add_char seg3 (advance s)
       done;
       let s3 = Buffer.contents seg3 in
       if s3 = "" then raise (LexError "expected digits in segment");
       (match peek s with
        | '.' when peek2 s <> '.' ->
          (* Fourth segment → IPv4 or CIDR *)
          ignore (advance s);
          let seg4 = Buffer.create 4 in
          while not (is_at_end s) && is_digit (peek s) do
            Buffer.add_char seg4 (advance s)
          done;
          let s4 = Buffer.contents seg4 in
          if s4 = "" then raise (LexError "expected digits in segment");
          let octet_ok seg =
            match int_of_string_opt seg with
            | Some n -> n >= 0 && n <= 255
            | None   -> false
          in
          if not (octet_ok first && octet_ok s2 && octet_ok s3 && octet_ok s4) then
            raise (LexError (Printf.sprintf "invalid IPv4 address: each octet must be 0–255"));
          let ipv4 = Printf.sprintf "%s.%s.%s.%s" first s2 s3 s4 in
          if peek s = '/' && is_digit (peek2 s) then begin
            ignore (advance s);
            let prefix = Buffer.create 3 in
            while not (is_at_end s) && is_digit (peek s) do
              Buffer.add_char prefix (advance s)
            done;
            let prefix_str = Buffer.contents prefix in
            (match int_of_string_opt prefix_str with
             | Some n when n >= 0 && n <= 32 ->
               CIDR (ipv4 ^ "/" ^ prefix_str)
             | _ ->
               raise (LexError (Printf.sprintf "invalid CIDR prefix: must be 0–32")))
          end else
            IPv4 ipv4
        | _ ->
          (* Three segments → Version, optionally with pre-release *)
          let base = Printf.sprintf "%s.%s.%s" first s2 s3 in
          if peek s = '-' then begin
            ignore (advance s);
            let pre = Buffer.create 8 in
            Buffer.add_char pre '-';
            while not (is_at_end s)
               && (is_alnum_or_under (peek s) || peek s = '.' || peek s = '-') do
              Buffer.add_char pre (advance s)
            done;
            Version (base ^ Buffer.contents pre)
          end else
            Version base)
     | c when is_upper c ->
       (* e.g. 1.5GB *)
       (match try_read_size_unit s with
        | Some unit -> Size (first ^ "." ^ s2 ^ unit)
        | None -> Float (float_of_string (first ^ "." ^ s2)))
     | _ ->
       Float (float_of_string (first ^ "." ^ s2)))

  (* Dash: Date or DateTime (requires exactly 4-digit year) *)
  | '-' when String.length first = 4
          && is_digit (char_at s 1) && is_digit (char_at s 2)
          && char_at s 3 = '-'
          && is_digit (char_at s 4) && is_digit (char_at s 5) ->
    ignore (advance s);
    let mm1 = advance s and mm2 = advance s in
    ignore (advance s);
    let dd1 = advance s and dd2 = advance s in
    let date = Printf.sprintf "%s-%c%c-%c%c" first mm1 mm2 dd1 dd2 in
    if peek s = 'T' then begin
      let dt = Buffer.create 24 in
      Buffer.add_string dt date;
      while not (is_at_end s)
         && (is_digit (peek s) || List.mem (peek s) ['T';':';'Z';'+';'-']) do
        Buffer.add_char dt (advance s)
      done;
      DateTime (Buffer.contents dt)
    end else
      Date date

  (* Colon: Time (requires exactly 2-digit hour) *)
  | ':' when String.length first = 2
          && is_digit (char_at s 1) && is_digit (char_at s 2)
          && char_at s 3 = ':'
          && is_digit (char_at s 4) && is_digit (char_at s 5) ->
    ignore (advance s);
    let mm1 = advance s and mm2 = advance s in
    ignore (advance s);
    let ss1 = advance s and ss2 = advance s in
    Time (Printf.sprintf "%s:%c%c:%c%c" first mm1 mm2 ss1 ss2)

  (* Duration suffix (lowercase unit letters) *)
  | c when is_duration_start c ->
    read_duration s first

  (* Size unit or plain Int *)
  | _ ->
    (match try_read_size_unit s with
     | Some unit -> Size (first ^ unit)
     | None      -> Int (int_of_string first))

(* ── Regex literals: r/pattern/flags ────────────────────────────────────── *)

let read_regex s =
  ignore (advance s); (* consume opening '/' *)
  let buf = Buffer.create 16 in
  let rec loop () =
    if is_at_end s then raise (LexError "unterminated regex literal");
    match advance s with
    | '\\' ->
      Buffer.add_char buf '\\';
      if not (is_at_end s) then Buffer.add_char buf (advance s);
      loop ()
    | '/' -> () (* closing slash *)
    | c   -> Buffer.add_char buf c; loop ()
  in
  loop ();
  let pat = Buffer.contents buf in
  let flags = Buffer.create 4 in
  while not (is_at_end s) && List.mem (peek s) ['i'; 'm'; 's'] do
    Buffer.add_char flags (advance s)
  done;
  Regex (pat, Buffer.contents flags)

(* ── Identifiers ─────────────────────────────────────────────────────────── *)

let read_ident s first_char =
  let buf = Buffer.create 8 in
  Buffer.add_char buf first_char;
  while not (is_at_end s) && is_alnum_or_under (peek s) do
    Buffer.add_char buf (advance s)
  done;
  (* Consume one trailing ? or ! suffix (predicate / bang convention) *)
  if not (is_at_end s) && peek s = '?' then
    Buffer.add_char buf (advance s)
  else if not (is_at_end s) && peek s = '!' && peek2 s <> '=' then
    Buffer.add_char buf (advance s);
  let word = Buffer.contents buf in
  (* let* *)
  if word = "let" && peek s = '*' then (ignore (advance s); LetStar)
  (* Regex literal: r/pattern/flags — only when r is followed immediately by / *)
  else if word = "r" && peek s = '/' then read_regex s
  (* URL: http:// or https:// *)
  else if (word = "http" || word = "https")
       && peek s = ':' && peek2 s = '/' && char_at s 2 = '/' then
    read_url s word
  else
    keyword_or_ident word

(* ── Port ───────────────────────────────────────────────────────────────── *)

let read_port s =
  let buf = Buffer.create 5 in
  while not (is_at_end s) && is_digit (peek s) do
    Buffer.add_char buf (advance s)
  done;
  Port (int_of_string (Buffer.contents buf))

(* ── Main tokeniser ─────────────────────────────────────────────────────── *)

let next_token s =
  let rec scan () =
    let l = s.line and c = s.col in
    let loc = Token.{ line = l; col = c } in
    let ret tok = (tok, loc) in
    if is_at_end s then ret EOF
    else match advance s with
    | ' ' | '\t' | '\r' -> scan ()
    | '\n' -> ret Newline
    | '"'  -> ret (read_string s)
    | '('  when peek s = '*' ->
      (match read_comment s with
       | None -> scan ()
       | Some doc -> ret (DocComment doc))
    | '('  -> ret LParen
    | ')'  -> ret RParen
    | '['  -> ret LBracket
    | ']'  -> ret RBracket
    | '{'  -> ret LBrace
    | '}'  -> ret RBrace
    | ','  -> ret Comma
    | ';'  -> ret Semicolon
    | '?'  ->
      if not (is_at_end s) && (is_path_body_char (peek s) || is_glob_char (peek s)) then
        ret (read_path_body s "?")
      else
        ret Hole
    | '+'  -> ret (if peek s = '+' then (ignore (advance s); PlusPlus) else Plus)
    | '*'  ->
      (* ** or *.foo etc → Glob; bare * → Star (multiplication) *)
      let prefix = if peek s = '*' then (ignore (advance s); "**") else "*" in
      if not (is_at_end s) && (is_path_body_char (peek s) || is_glob_char (peek s)) then
        ret (read_path_body s prefix)
      else
        ret (if prefix = "**" then Glob "**" else Star)
    | '%'  -> ret Percent
    | '!'  -> ret (if peek s = '=' then (ignore (advance s); BangEq) else Bang)
    | '='  -> ret (if peek s = '=' then (ignore (advance s); EqEq)  else Eq)
    | '<'  -> ret (if peek s = '=' then (ignore (advance s); LtEq)  else Lt)
    | '>'  -> ret (if peek s = '=' then (ignore (advance s); GtEq)  else Gt)
    | '&'  -> if peek s = '&' then ret (ignore (advance s); AmpAmp)
              else raise (LexError "unexpected '&'")
    | '|'  -> ret (match peek s with
               | '>' -> ignore (advance s); PipeArrow
               | '|' -> ignore (advance s); PipePipe
               | _   -> Pipe)
    | '-'  -> ret (if peek s = '>' then (ignore (advance s); Arrow) else Minus)
    | ':'  -> ret (if is_digit (peek s) then read_port s else Colon)
    | '/'  ->
      ret (if not (is_at_end s) && (is_alpha (peek s) || is_digit (peek s)
                                    || peek s = '_' || peek s = '.') then
             read_path_body s "/"
           else Slash)
    | '.'  ->
      ret (match peek s with
       | '/' -> ignore (advance s); read_path_body s "./"
       | '.' when peek2 s = '/' ->
         ignore (advance s); ignore (advance s); read_path_body s "../"
       | '.' -> ignore (advance s); DotDot
       | _   -> Dot)
    | '$'  ->
      if peek s = '?' && peek2 s = '(' then (
        ignore (advance s); ignore (advance s);
        let raw = read_run_cmd s in
        ret (match raw with
          | RunCmdRaw (parts, tail) -> RunQueryRaw (parts, tail)
          | t -> t))
      else if peek s = '(' then (ignore (advance s); ret (read_run_cmd s))
      else if is_upper (peek s) then
        let buf = Buffer.create 8 in
        while not (is_at_end s) && (is_upper (peek s) || is_digit (peek s) || peek s = '_') do
          Buffer.add_char buf (advance s)
        done;
        ret (EnvVar (Buffer.contents buf))
      else ret Dollar
    | '~'  ->
      ret (if peek s = '/' then (ignore (advance s); read_path_body s "~/")
           else raise (LexError "unexpected '~'"))
    | '\'' ->
      if is_at_end s || not (is_lower (peek s)) then
        raise (LexError "expected lowercase letter after '''")
      else begin
        let buf = Buffer.create 8 in
        Buffer.add_char buf (advance s);
        while not (is_at_end s) && is_alnum_or_under (peek s) do
          Buffer.add_char buf (advance s)
        done;
        ret (TypeVar (Buffer.contents buf))
      end
    | c when is_digit c -> ret (read_numeric s c)
    | c when is_alpha c || c = '_' -> ret (read_ident s c)
    | c -> raise (LexError (Printf.sprintf "unexpected character '%c'" c))
  in
  scan ()

let tokenize src =
  let s = make src in
  (* skip shebang line if present *)
  if String.length src >= 2 && src.[0] = '#' && src.[1] = '!' then
    while not (is_at_end s) && peek s <> '\n' do ignore (advance s) done;
  let toks = ref [] in
  let rec loop () =
    let (t, loc) = next_token s in
    toks := (t, loc) :: !toks;
    if t <> EOF then loop ()
  in
  loop ();
  List.rev !toks

let tokenize_plain src = List.map fst (tokenize src)
