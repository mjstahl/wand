open Token

(* Raised inside the scanner, where only the message is known. `tokenize`
   turns it into `LexError` with the position of the token being read --
   internal raises need not thread a location they cannot improve on. *)
exception Fail of string

exception LexError of Token.loc * string

type state = {
  src  : string;
  mutable pos  : int;
  mutable line : int;
  mutable col  : int;
  (* where the token being scanned began -- the position a failure inside
     `next_token` is reported at, so an unterminated string points at its
     opening quote rather than at end of file. *)
  mutable tok_start : Token.loc;
}

let make src =
  { src; pos = 0; line = 1; col = 1; tok_start = Token.point 1 1 0 }

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
  | "import"   -> Import
  | "requires" -> Requires
  | "ensures"  -> Ensures  | "result"   -> Result
  | "fn"       -> Fn       | "fun"      -> Fn
  | "of"       -> Of
  | "for"      -> For      | "do"       -> Do
  | "end"      -> End      | "class"    -> Class
  | "instance" -> Instance | "orphan"   -> Orphan
  | "when"     -> When     | "and"      -> And
  | "as"       -> As
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
    if is_at_end s then raise (Fail "unterminated string literal");
    match advance s with
    | '"'  ->
      if !parts = [] then String (Buffer.contents buf)
      else InterpStr (!parts, Buffer.contents buf)
    | '\\' ->
      let c = match advance s with
        | 'n' -> '\n' | 't' -> '\t' | 'r' -> '\r'
        | '\\' -> '\\' | '"' -> '"' | '$' -> '$' | '%' -> '%' | '#' -> '#'
        | c -> raise (Fail (Printf.sprintf "unknown escape \\%c" c))
      in
      Buffer.add_char buf c; loop ()
    (* A string is text, not a command line: there are no argument
       boundaries to quote for, so raw interpolation would mean exactly what
       `%{...}` already means. Rejected rather than allowed as a synonym. *)
    | '%' when peek s = '!' && peek2 s = '{' ->
      raise (Fail "%!{...} is for shell commands, where it splices a \
                       value as shell source. A string has nothing to quote \
                       for, so write %{...} here.")
    (* `$` used to interpolate. It now means one thing -- reaching outside
       the program, as `$(cmd)` and `$NAME` do -- and text assembly is `%`.
       Refused for a release rather than read as literal text, because a
       `"${x}"` that quietly became the characters `${x}` is a wrong answer
       no one would look for. *)
    | '$' when peek s = '{' || (peek s = '!' && peek2 s = '{') ->
      raise (Fail "interpolation is %{...}, not ${...}. For the \
                       literal text, write \\${...}")
    (* The Ruby/Elixir spelling, refused for the same reason as `${...}`:
       text that quietly stayed text is a wrong answer no one would look
       for. *)
    | '#' when peek s = '{' ->
      raise (Fail "interpolation is %{...}, not #{...}. For the literal \
                       text, write \\#{...}")
    | '%' when peek s = '{' ->
      ignore (advance s);
      let lit = Buffer.contents buf in
      Buffer.clear buf;
      let expr_buf = Buffer.create 16 in
      let depth = ref 1 in
      while !depth > 0 do
        if is_at_end s then raise (Fail "unterminated string interpolation");
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
    (* `$NAME` is text here. Reading the environment is an expression like
       any other, so it goes through the one interpolation form -- write
       `%{$HOME}`. What this buys is that a string holding shell or Make
       source keeps it: `$HOME`, `$PATH`, `$(date)` all survive as written,
       and there is no longer a spelling that means one thing in text and
       another in code. *)
    | c -> Buffer.add_char buf c; loop ()
  in
  loop ()

(* ── Raw string literals: `...` ─────────────────────────────────────────── *)

(* Between backticks every character is itself. There are no escapes, so a
   backslash is a backslash and a double quote is just a quote -- which is
   the point: JSON,
   a regex, a Windows path and a here-doc can all be pasted in as they are.

   `%{...}` still interpolates, because a string form that could not take a
   value would only send people back to `"..."` and its escaping. That makes
   `%{` the one sequence a raw string cannot hold; an ordinary quoted string
   escapes it as backslash-percent, and needing that is rarer than
   everything this buys.

   A newline straight after the opening backtick is not part of the text, so
   a literal can start on its own line without the string starting blank.
   Nothing else is trimmed: trailing spaces, indentation and the final
   newline are all kept, since a raw string is for text whose shape matters. *)
let read_raw_string s =
  (* The opening backtick is consumed; drop a newline that follows it. *)
  if peek s = '\n' then ignore (advance s)
  else if peek s = '\r' && peek2 s = '\n' then (ignore (advance s); ignore (advance s));
  let parts = ref [] in
  let buf = Buffer.create 32 in
  let rec loop () =
    if is_at_end s then raise (Fail "unterminated `...` string");
    match advance s with
    | '`' ->
      if !parts = [] then RawStr (Buffer.contents buf)
      else RawInterpStr (!parts, Buffer.contents buf)
    | '%' when peek s = '!' && peek2 s = '{' ->
      raise (Fail "%!{...} is for shell commands, where it splices a \
                       value as shell source. A string has nothing to quote \
                       for, so write %{...} here.")
    | '%' when peek s = '{' ->
      ignore (advance s);
      let lit = Buffer.contents buf in
      Buffer.clear buf;
      let expr_buf = Buffer.create 16 in
      let depth = ref 1 in
      while !depth > 0 do
        if is_at_end s then
          raise (Fail "unterminated %{...} interpolation in a `...` \
                           string. A `...` string cannot hold a literal %{ \
                           -- for that text, use an ordinary \"...\" string \
                           and write \\%{");
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
    | c -> Buffer.add_char buf c; loop ()
  in
  loop ()

(* ── Run-command literals: $(cmd %{var}) ────────────────────────────────── *)

let read_run_cmd s =
  let parts = ref [] in
  let buf = Buffer.create 16 in
  let depth = ref 1 in
  (* The shell's own quoting, tracked because the command ends at a `)` and
     a quoted one is not the end of anything: `$(echo "a)b")` is one
     command, and counting parens blind cut it in half -- taking the rest of
     the line with it, since what followed was read as wand source. Tracked
     only that far: which quote is open, and whether a backslash spent the
     next character. *)
  let quote = ref ' ' in
  let rec loop () =
    if is_at_end s then
      raise (Fail (if !quote = ' ' then "unterminated $() command"
                   else Printf.sprintf
                     "unterminated $() command: a %c quote is still open"
                     !quote));
    match advance s with
    | '(' when !quote = ' ' ->
      incr depth; Buffer.add_char buf '('; loop ()
    | ')' when !quote = ' ' ->
      decr depth;
      if !depth > 0 then (Buffer.add_char buf ')'; loop ())
      else (* closing paren — done *)
        RunCmdRaw (!parts, Buffer.contents buf)
    (* `%{x}` quotes, `%!{x}` splices. Both read the same expression source;
       they differ only in what the evaluator does with the value.

       `$` keeps its own job inside a command, which is the shell's: `$HOME`
       and `$(date)` here are text the shell will expand, and wand no longer
       competes for them. *)
    | '$' when peek s = '{' || (peek s = '!' && peek2 s = '{') ->
      raise (Fail "interpolation is %{...}, not ${...}. For a \
                       variable the shell should expand, $ needs no escape \
                       -- write $NAME or ${NAME} once this release is past")
    | '%' when peek s = '{' || (peek s = '!' && peek2 s = '{') ->
      let raw = peek s = '!' in
      if raw then ignore (advance s);
      ignore (advance s);
      let lit = Buffer.contents buf in
      Buffer.clear buf;
      let expr_buf = Buffer.create 16 in
      let idepth = ref 1 in
      while !idepth > 0 do
        if is_at_end s then raise (Fail "unterminated command interpolation");
        let c = advance s in
        if c = '{' then (incr idepth; Buffer.add_char expr_buf c)
        else if c = '}' then begin
          decr idepth;
          if !idepth > 0 then Buffer.add_char expr_buf c
        end else
          Buffer.add_char expr_buf c
      done;
      (* Backticks are not a quote the value has to be escaped for: what is
         inside them is source for a shell of its own, which reads an
         ordinary single-quoted argument exactly as the outer one would. *)
      let hole =
        if raw then Token.Source
        else match !quote with
          | '\'' | '"' as q -> Token.Inside q
          | _ -> Token.Arg
      in
      parts := !parts @ [(lit, Buffer.contents expr_buf, hole)];
      loop ()
    | '\\' when peek s = '\n' -> ignore (advance s); loop ()
    (* A backslash spends the next character wherever the shell would let it
       -- everywhere but inside single quotes, where it is itself. *)
    | '\\' when !quote <> '\'' && not (is_at_end s) ->
      Buffer.add_char buf '\\'; Buffer.add_char buf (advance s); loop ()
    | ('\'' | '"' | '`') as c when !quote = ' ' ->
      quote := c; Buffer.add_char buf c; loop ()
    | c when c = !quote ->
      quote := ' '; Buffer.add_char buf c; loop ()
    | c -> Buffer.add_char buf c; loop ()
  in
  loop ()

(* ── Comments ───────────────────────────────────────────────────────────── *)

(* `--` runs to the end of the line. The newline itself is left unconsumed so
   the following `Newline` token is still produced -- statement termination
   must not depend on whether a line ends in a comment. *)
let read_line_comment s =
  ignore (advance s);  (* consume second '-' *)
  let buf = Buffer.create 64 in
  while not (is_at_end s) && peek s <> '\n' do
    Buffer.add_char buf (advance s)
  done;
  Buffer.contents buf

(* ── Paths ──────────────────────────────────────────────────────────────── *)

let read_path_body s prefix =
  let buf = Buffer.create 16 in
  Buffer.add_string buf prefix;
  let has_glob = ref (String.exists is_glob_char prefix) in
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
    if s2 = "" then raise (Fail "expected digits after '.'");
    (match peek s with
     | '.' when peek2 s <> '.' ->
       (* Third segment → Version or IPv4 *)
       ignore (advance s);
       let seg3 = Buffer.create 4 in
       while not (is_at_end s) && is_digit (peek s) do
         Buffer.add_char seg3 (advance s)
       done;
       let s3 = Buffer.contents seg3 in
       if s3 = "" then raise (Fail "expected digits in segment");
       (match peek s with
        | '.' when peek2 s <> '.' ->
          (* Fourth segment → IPv4 or CIDR *)
          ignore (advance s);
          let seg4 = Buffer.create 4 in
          while not (is_at_end s) && is_digit (peek s) do
            Buffer.add_char seg4 (advance s)
          done;
          let s4 = Buffer.contents seg4 in
          if s4 = "" then raise (Fail "expected digits in segment");
          let octet_ok seg =
            match int_of_string_opt seg with
            | Some n -> n >= 0 && n <= 255
            | None   -> false
          in
          if not (octet_ok first && octet_ok s2 && octet_ok s3 && octet_ok s4) then
            raise (Fail "invalid IPv4 address: each octet must be 0–255");
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
               raise (Fail "invalid CIDR prefix: must be 0–32"))
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
      (* A bare date is a spelling of midnight UTC, not a type of its own.
         One instant type, one resolution: `2026-08-22 + 5h` moves five
         hours, where two types needed a rule for each to stand still at
         its own.

         The text is kept as it was written, the way an offset form is:
         `datetime_epoch` reads the meaning out of either, and a formatter
         that expanded this would delete a spelling the language offers. *)
      DateTime date

  (* Colon: a time of day, which is not a value. The shape is still read,
     so the refusal can name what to write instead of failing on the `:`
     somewhere further along. A time of day belongs to a day. *)
  | ':' when String.length first = 2
          && is_digit (char_at s 1) && is_digit (char_at s 2)
          && char_at s 3 = ':'
          && is_digit (char_at s 4) && is_digit (char_at s 5) ->
    ignore (advance s);
    let mm1 = advance s and mm2 = advance s in
    ignore (advance s);
    let ss1 = advance s and ss2 = advance s in
    let t = Printf.sprintf "%s:%c%c:%c%c" first mm1 mm2 ss1 ss2 in
    raise (Fail (Printf.sprintf
      "a time of day is not a value on its own -- write the instant, \
       2026-08-22T%s, or a Duration onto a day, DateTime.on! 2026 8 22 + %sh"
      t (String.sub t 0 2)))

  (* Duration suffix (lowercase unit letters) *)
  | c when is_duration_start c ->
    read_duration s first

  (* Size unit or plain Int *)
  | _ ->
    (match try_read_size_unit s with
     | Some unit -> Size (first ^ unit)
     | None ->
       (* A number too large for an Int is a lex error like any other. It
          used to reach `int_of_string`, whose failure escaped as OCaml's own
          -- the reader got "Error: int_of_string" and nothing about where. *)
       (match int_of_string_opt first with
        | Some n -> Int n
        | None ->
          raise (Fail (Printf.sprintf
            "%s is too large for an Int, which holds up to %d" first max_int))))

(* ── Regex literals: r/pattern/flags ────────────────────────────────────── *)

let read_regex s =
  ignore (advance s); (* consume opening '/' *)
  let buf = Buffer.create 16 in
  let rec loop () =
    if is_at_end s then raise (Fail "unterminated regex literal");
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

(* A port is a number from 0 to 65535. Outside that it is not a port, and a
   program that says so is wrong about something. Checked here rather than at
   each reader, so a literal, `String.to_port` and `Decode.port` cannot
   disagree about the same number -- they all come through this. *)
let read_port s =
  let buf = Buffer.create 5 in
  while not (is_at_end s) && is_digit (peek s) do
    Buffer.add_char buf (advance s)
  done;
  let digits = Buffer.contents buf in
  match int_of_string_opt digits with
  | Some n when n <= 65535 -> Port n
  | _ ->
    (* Also the arm for a number too large to be an Int at all, which used to
       escape as an OCaml failure rather than a lex error. *)
    raise (Fail (Printf.sprintf "invalid port :%s: must be 0-65535" digits))

(* ── Main tokeniser ─────────────────────────────────────────────────────── *)

let next_token s =
  let rec scan () =
    let l = s.line and c = s.col and o = s.pos in
    let loc = Token.point l c o in
    s.tok_start <- loc;
    (* `ret` runs after its argument is scanned, so the state now sits just
       past the token -- exactly the exclusive end the loc records. *)
    let ret tok =
      (tok, { loc with Token.end_line = s.line; end_col = s.col;
                       end_offset = s.pos }) in
    if is_at_end s then ret EOF
    else match advance s with
    | ' ' | '\t' | '\r' -> scan ()
    | '\n' -> ret Newline
    | '"'  -> ret (read_string s)
    | '`'  -> ret (read_raw_string s)
    | '('  when peek s = '*' ->
      raise (Fail "a comment is '-- ...' to the end of the line; write \
                       each line of this one with '--'")
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
    | '+' when peek s = '.' ->
      raise (Fail "operators are not spelled differently for Float -- \
                       there is no '+.'")
    | '+'  -> ret (if peek s = '+' then (ignore (advance s); PlusPlus) else Plus)
    | '*'  ->
      (* ** or *.foo etc → Glob; bare * → Star (multiplication) *)
      let prefix = if peek s = '*' then (ignore (advance s); "**") else "*" in
      if not (is_at_end s) && (is_path_body_char (peek s) || is_glob_char (peek s)) then
        (* `a *. b` reads as the glob "*." otherwise, and the type error it
           produces ("expected Glob, got ...") points nowhere near the
           mistake. A real glob always has more after the dot. *)
        (match read_path_body s prefix with
         | Glob "*." ->
           raise (Fail "operators are not spelled differently for Float \
                            -- there is no '*.'")
         | t -> ret t)
      else
        ret (if prefix = "**" then Glob "**" else Star)
    | '%'  -> ret Percent
    | '!'  -> ret (if peek s = '=' then (ignore (advance s); BangEq) else Bang)
    | '='  -> ret (if peek s = '=' then (ignore (advance s); EqEq)  else Eq)
    (* `<>` is inequality in several ML dialects and in SQL, so it is a
       reasonable thing to type. Saying which operator this language uses
       costs one line and saves the reader guessing from `unexpected '>'`. *)
    | '<' when peek s = '>' -> raise (Fail "the inequality operator is !=, not <>")
    | '<'  -> ret (if peek s = '=' then (ignore (advance s); LtEq)  else Lt)
    | '>'  -> ret (if peek s = '=' then (ignore (advance s); GtEq)  else Gt)
    | '&'  -> if peek s = '&' then ret (ignore (advance s); AmpAmp)
              else raise (Fail "unexpected '&'")
    | '^'  ->
      raise (Fail "string concatenation is '++', not '^'")
    | '|'  -> ret (match peek s with
               | '>' -> ignore (advance s); PipeArrow
               | '|' -> ignore (advance s); PipePipe
               | _   -> Pipe)
    | '-' when peek s = '.' ->
      raise (Fail "operators are not spelled differently for Float -- \
                       there is no '-.'")
    | '-'  ->
      ret (match peek s with
       | '>' -> ignore (advance s); Arrow
       | '-' -> LineComment (read_line_comment s)
       | _   -> Minus)
    (* `::` is cons. `:` gives a name a type, and reads a port when a digit
       follows it -- this branch runs first, so `::80` is a cons of 80 and
       never a port. *)
    | ':' when peek s = ':' -> ignore (advance s); ret DoubleColon
    | ':' when peek s = '=' ->
      raise (Fail "there is no mutation, so there is no ':=' -- \
                       let binds a new name instead")
    | ':'  -> ret (if is_digit (peek s) then read_port s else Colon)
    | '/' when peek s = '/' ->
      raise (Fail "a comment is '-- ...' to the end of the line, not '//'")
    | '/'  ->
      if not (is_at_end s) && (is_alpha (peek s) || is_digit (peek s)
                               || peek s = '_' || peek s = '.') then
        (* `a /. b` reads as the path "/." otherwise, and the type error it
           produces ("expected Path, got ...") points nowhere near the
           mistake. *)
        (match read_path_body s "/" with
         | Path "/." ->
           raise (Fail "operators are not spelled differently for Float \
                            -- there is no '/.'")
         | t -> ret t)
      else ret Slash
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
           else raise (Fail "unexpected '~'"))
    | '\'' ->
      if is_at_end s || not (is_lower (peek s)) then
        raise (Fail "expected a type variable like 'a after ''' -- and \
                         there are no character literals: a one-character \
                         string is \"x\"")
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
    | '\\' when is_alpha (peek s) || peek s = '_' || peek s = '(' ->
      raise (Fail "a lambda is 'fn x -> ...', not '\\x -> ...'")
    (* The shebang on line one is handled in `tokenize`; any other `#` is a
       comment reflex from bash or Python. *)
    | '#' ->
      raise (Fail "a comment is '-- ...' to the end of the line, not '# ...'")
    | c -> raise (Fail (Printf.sprintf "unexpected character '%c'" c))
  in
  scan ()

let tokenize src =
  let s = make src in
  (* skip shebang line if present *)
  if String.length src >= 2 && src.[0] = '#' && src.[1] = '!' then
    while not (is_at_end s) && peek s <> '\n' do ignore (advance s) done;
  let toks = ref [] in
  let rec loop () =
    let (t, loc) =
      try next_token s
      with Fail msg ->
        (* The range runs from the failing token's start to wherever the
           scan stopped, so the whole partial token is marked. *)
        raise (LexError ({ s.tok_start with Token.end_line = s.line;
                           end_col = s.col; end_offset = s.pos }, msg))
    in
    toks := (t, loc) :: !toks;
    if t <> EOF then loop ()
  in
  loop ();
  List.rev !toks

let tokenize_plain src = List.map fst (tokenize src)
