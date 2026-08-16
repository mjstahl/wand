(* Finds the command words of a shell command line: the first word, and the
   first word after each top-level `|`, `&&`, `||`, `;`, `&`. This is what
   a `Shell(git, curl)` manifest is checked against -- statically over the
   written text, and again at spawn over the resolved text.

   Deliberately not a shell parser. Quotes are tracked exactly as far as
   telling a real `|` from a quoted one; parentheses and backticks make
   their contents opaque (a subshell is text handed to the named binary's
   shell, not a position of this file); redirections are skipped along with
   their targets. Wrappers (`env`, `xargs`, `sh`) are *not* peeled: the
   wrapper is the thing the manifest allows. *)

(* One piece of a command template as written: literal text, a quoted
   `%{...}` splice (always exactly one argument -- it cannot introduce
   operators), or a raw `%!{...}` splice (shell source: everything after
   it is data, structurally unknowable until the value arrives). *)
type seg =
  | Lit of string
  | QuotedHole
  | RawHole

type word_class =
  | Literal  of string   (* checkable, now or at spawn *)
  | Dynamic              (* an interpolation reaches into the word *)
  | Compound of string   (* a shell reserved word: control flow, not a binary *)

type scan = {
  words    : word_class list;  (* one per command position found *)
  raw_tail : bool;             (* a %!{...} appeared: the scan stops there *)
}

(* POSIX reserved words, plus `function`. Any of these in command position
   means the line's real commands live inside a compound body that neither
   the static check nor the spawn check can bound. `time` is deliberately
   absent: `time cmd` is a wrapper, and wrappers are the thing a manifest
   allows. *)
let reserved = [
  "if"; "then"; "elif"; "else"; "fi";
  "for"; "while"; "until"; "do"; "done";
  "case"; "esac"; "{"; "}"; "!"; "function";
]

let is_assignment w =
  (* NAME=value before the command word is an environment prefix; an
     assignment cannot execute anything. *)
  match String.index_opt w '=' with
  | None | Some 0 -> false
  | Some i ->
    let name_char j c =
      (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_'
      || (j > 0 && c >= '0' && c <= '9')
    in
    let rec ok j = j >= i || (name_char j w.[j] && ok (j + 1)) in
    ok 0

let scan (segs : seg list) : scan =
  let words = ref [] in
  let buf = Buffer.create 16 in
  let has_hole = ref false in
  let expecting = ref true in      (* the next word is a command word *)
  let skip_target = ref false in   (* the next word is a redirection target *)
  let raw_tail = ref false in
  let finish_word () =
    let w = Buffer.contents buf in
    Buffer.clear buf;
    let dynamic = !has_hole in
    has_hole := false;
    if w = "" && not dynamic then ()
    else if !skip_target then skip_target := false
    else if not !expecting then ()
    else if dynamic then (words := Dynamic :: !words; expecting := false)
    else if is_assignment w then ()  (* still expecting the command word *)
    else if List.mem w reserved then
      (words := Compound w :: !words; expecting := false)
    else (words := Literal w :: !words; expecting := false)
  in
  let scan_lit text =
    let n = String.length text in
    let i = ref 0 in
    let quote = ref ' ' in         (* ' ', '\'', '"', '`' *)
    let depth = ref 0 in           (* unclosed ( -- subshell text is opaque *)
    let peek k = if !i + k < n then text.[!i + k] else '\000' in
    while !i < n do
      let c = text.[!i] in
      if !quote <> ' ' then begin
        (* Inside quotes everything is word text; backslash keeps a double
           quote from closing. *)
        if c = '\\' && !quote = '"' && !i + 1 < n then begin
          if !depth = 0 then (Buffer.add_char buf c; Buffer.add_char buf (peek 1));
          i := !i + 2
        end else begin
          if c = !quote then quote := ' '
          else if !depth = 0 then Buffer.add_char buf c;
          incr i
        end
      end else if !depth > 0 then begin
        (* Subshell text: only track nesting and quotes, keep nothing. *)
        (match c with
         | '(' -> incr depth
         | ')' -> decr depth
         | '\'' | '"' | '`' -> quote := c
         | _ -> ());
        incr i
      end else
        match c with
        | '\'' | '"' | '`' -> quote := c; incr i
        | '\\' when !i + 1 < n ->
          Buffer.add_char buf (peek 1); i := !i + 2
        | ' ' | '\t' | '\n' -> finish_word (); incr i
        | '(' -> finish_word (); incr depth; incr i
        | ')' -> finish_word (); incr i
        | '|' ->
          finish_word (); expecting := true;
          i := !i + (if peek 1 = '|' || peek 1 = '&' then 2 else 1)
        | '&' ->
          finish_word (); expecting := true;
          i := !i + (if peek 1 = '&' then 2 else 1)
        | ';' -> finish_word (); expecting := true; incr i
        | '<' | '>' ->
          (* A redirection: any digits gathered so far are its fd prefix,
             not a word. `>&2`-style forms carry their own target. *)
          if Buffer.contents buf <> ""
             && String.for_all (fun d -> d >= '0' && d <= '9')
                  (Buffer.contents buf)
          then Buffer.clear buf
          else finish_word ();
          let j = ref (!i + 1) in
          if !j < n && (text.[!j] = '>' || text.[!j] = '<') then incr j;
          if !j < n && text.[!j] = '&' then begin
            incr j;
            while !j < n && text.[!j] >= '0' && text.[!j] <= '9' do incr j done
          end else skip_target := true;
          i := !j
        | c -> Buffer.add_char buf c; incr i
    done
  in
  (try
     List.iter (fun seg ->
       match seg with
       | Lit text -> scan_lit text
       | QuotedHole -> has_hole := true
       | RawHole ->
         (* Shell source arrives here at runtime; nothing after it can be
            read structurally from the written text. The spawn-time rescan
            of the resolved line picks up where this leaves off. *)
         raw_tail := true;
         if !expecting then words := Dynamic :: !words;
         raise Exit)
       segs;
     finish_word ()
   with Exit -> ());
  { words = List.rev !words; raw_tail = !raw_tail }

(* The runtime side: the resolved command line, no holes left. *)
let scan_string text = scan [Lit text]

(* An entry without a slash matches the word's final path component, so
   `git` admits both `git` and `/usr/bin/git`; an entry with a slash
   matches the whole word exactly. *)
let allowed ~allow word =
  List.exists (fun entry ->
    if String.contains entry '/' then entry = word
    else entry = word || entry = Filename.basename word)
    allow

(* The command template a $()/$?() payload was written as. Anything that is
   not literal text or a recognisable interpolation -- an arbitrary
   expression in command position -- reads as raw: its shape arrives at
   run time. *)
let rec segs_of_cmd (e : Ast.expr) : seg list =
  match e with
  | Ast.Located (_, inner) -> segs_of_cmd inner
  | Ast.String cmd | Ast.RawString cmd -> [Lit cmd]
  | Ast.CmdInterp (parts, tail) ->
    List.concat_map (fun (lit, _, raw) ->
      [Lit lit; (if raw then RawHole else QuotedHole)]) parts
    @ [Lit tail]
  | _ -> [RawHole]

(* One manifest label back as source text: `Shell(git, "docker-compose")`.
   An entry is bare when it re-lexes as one word; quoted otherwise. *)
let render_entry w =
  let ident_char c =
    (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '_' in
  if w <> "" && String.for_all ident_char w && w.[0] >= 'a' && w.[0] <= 'z'
  then w
  else "\"" ^ w ^ "\""

let render_label = function
  | (name, None) -> name
  | (name, Some args) ->
    name ^ "(" ^ String.concat ", " (List.map render_entry args) ^ ")"
