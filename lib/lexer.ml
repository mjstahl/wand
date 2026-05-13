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

(* ── Keywords & identifiers ─────────────────────────────────────────────── *)

let keyword_or_ident word = match word with
  | "let"      -> Let      | "in"       -> In
  | "match"    -> Match    | "with"     -> With
  | "if"       -> If       | "then"     -> Then
  | "else"     -> Else     | "type"     -> Type
  | "token"    -> Token    | "import"   -> Import
  | "start"    -> Start    | "requires" -> Requires
  | "ensures"  -> Ensures  | "result"   -> Result
  | "fn"       -> Fn       | "of"       -> Of
  | "for"      -> For      | "do"       -> Do
  | "end"      -> End      | "class"    -> Class
  | "instance" -> Instance | "orphan"   -> Orphan
  | "when"     -> When     | "and"      -> And
  | "or"       -> Or
  | "true"     -> Bool true
  | "false"    -> Bool false
  | "_"        -> Underscore
  | s when s.[0] >= 'A' && s.[0] <= 'Z' -> Upper s
  | s          -> Ident s

(* ── String literals ────────────────────────────────────────────────────── *)

let read_string s =
  let buf = Buffer.create 16 in
  let rec loop () =
    if is_at_end s then raise (LexError "unterminated string literal");
    match advance s with
    | '"'  -> String (Buffer.contents buf)
    | '\\' ->
      let c = match advance s with
        | 'n' -> '\n' | 't' -> '\t' | 'r' -> '\r'
        | '\\' -> '\\' | '"' -> '"'
        | c -> raise (LexError (Printf.sprintf "unknown escape \\%c" c))
      in
      Buffer.add_char buf c; loop ()
    | c -> Buffer.add_char buf c; loop ()
  in
  loop ()

(* ── Comments ───────────────────────────────────────────────────────────── *)

let skip_comment s =
  ignore (advance s);  (* consume '*' after '(' *)
  let depth = ref 1 in
  while !depth > 0 do
    if is_at_end s then raise (LexError "unterminated comment");
    let c = advance s in
    if c = '(' && peek s = '*' then (ignore (advance s); incr depth)
    else if c = '*' && peek s = ')' then (ignore (advance s); decr depth)
  done

(* ── Paths ──────────────────────────────────────────────────────────────── *)

let read_path_body s prefix =
  let buf = Buffer.create 16 in
  Buffer.add_string buf prefix;
  while not (is_at_end s) && is_path_body_char (peek s) do
    Buffer.add_char buf (advance s)
  done;
  Path (Buffer.contents buf)

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
          let ipv4 = Printf.sprintf "%s.%s.%s.%s" first s2 s3 s4 in
          if peek s = '/' && is_digit (peek2 s) then begin
            ignore (advance s);
            let prefix = Buffer.create 3 in
            while not (is_at_end s) && is_digit (peek s) do
              Buffer.add_char prefix (advance s)
            done;
            CIDR (ipv4 ^ "/" ^ Buffer.contents prefix)
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

(* ── Identifiers ─────────────────────────────────────────────────────────── *)

let read_ident s first_char =
  let buf = Buffer.create 8 in
  Buffer.add_char buf first_char;
  while not (is_at_end s) && is_alnum_or_under (peek s) do
    Buffer.add_char buf (advance s)
  done;
  let word = Buffer.contents buf in
  (* let* *)
  if word = "let" && peek s = '*' then (ignore (advance s); LetStar)
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
    | '('  when peek s = '*' -> skip_comment s; scan ()
    | '('  -> ret LParen
    | ')'  -> ret RParen
    | '['  -> ret LBracket
    | ']'  -> ret RBracket
    | '{'  -> ret LBrace
    | '}'  -> ret RBrace
    | ','  -> ret Comma
    | ';'  -> ret Semicolon
    | '?'  -> ret Hole
    | '+'  -> ret Plus
    | '*'  -> ret Star
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
    | '$'  -> ret Dollar
    | '~'  ->
      ret (if peek s = '/' then (ignore (advance s); read_path_body s "~/")
           else raise (LexError "unexpected '~'"))
    | c when is_digit c -> ret (read_numeric s c)
    | c when is_alpha c || c = '_' -> ret (read_ident s c)
    | c -> raise (LexError (Printf.sprintf "unexpected character '%c'" c))
  in
  scan ()

let tokenize src =
  let s = make src in
  let toks = ref [] in
  let rec loop () =
    let (t, loc) = next_token s in
    toks := (t, loc) :: !toks;
    if t <> EOF then loop ()
  in
  loop ();
  List.rev !toks

let tokenize_plain src = List.map fst (tokenize src)
