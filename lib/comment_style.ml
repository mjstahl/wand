(* Rewriting a wand block comment as `--` lines.

   wand is moving to one comment form. A block comment counts its closers,
   so text holding a bare "*)" ends the comment early -- and quoted shell
   has one in every `case` arm. A `--` line reads no brackets at all, so
   pasted text survives whatever it holds.

   `wand f` runs this over the source before it formats, which makes the
   formatter the upgrade path: a file written the old way comes back written
   the new way, and the run of `--` lines above a definition is that
   definition's documentation.

   A comment with code after it on the same line is left alone, because
   `--` would comment that code out. Those are rewritten by hand. *)

let line_start src i =
  let j = ref i in
  while !j > 0 && src.[!j - 1] <> '\n' do decr j done;
  !j

(* The lexer's rule, applied to the source: closers are counted, not
   matched, so this ends where the lexer ends the comment. Answers one past
   the closing bracket. *)
let comment_end src start =
  let n = String.length src in
  let i = ref (start + 2) in
  let depth = ref 1 in
  while !depth > 0 && !i < n do
    if !i + 1 < n && src.[!i] = '(' && src.[!i + 1] = '*' then
      (incr depth; i := !i + 2)
    else if !i + 1 < n && src.[!i] = '*' && src.[!i + 1] = ')' then
      (decr depth; i := !i + 2)
    else incr i
  done;
  !i

let is_blank s = String.for_all (fun c -> c = ' ' || c = '\t' || c = '\r') s

let rstrip s =
  let j = ref (String.length s) in
  while !j > 0 && (s.[!j - 1] = ' ' || s.[!j - 1] = '\t' || s.[!j - 1] = '\r') do
    decr j
  done;
  String.sub s 0 !j

(* A doc comment is written with its continuation lines aligned under the
   opening delimiter, and sometimes with a `*` down the left. Neither is
   part of the prose. What sits deeper than that alignment is: a sample is
   indented under the sentence that introduces it, and `wand d` prints it
   that way. *)
let strip_marker line =
  let s = String.trim line in
  if String.length s > 1 && s.[0] = '*' && s.[1] = ' ' then
    let body = String.sub s 1 (String.length s - 1) in
    (* Keep whatever indentation followed the marker. *)
    let lead = String.length line - String.length s in
    String.make lead ' ' ^ body
  else line

let indent_of line =
  let i = ref 0 in
  while !i < String.length line && line.[!i] = ' ' do incr i done;
  !i

let drop_blank_ends lines =
  let rec drop = function "" :: t -> drop t | l -> l in
  lines |> drop |> List.rev |> drop |> List.rev

(* The comment's prose as `--` lines, each carrying `indent`. The first line
   starts right after the delimiter, so it has no indentation of its own;
   the rest are aligned under it, and that shared alignment comes off while
   anything deeper stays. *)
let render indent inner =
  let lines =
    match String.split_on_char '\n' inner with
    | [] -> []
    | first :: rest ->
      let rest = List.map (fun l -> rstrip (strip_marker l)) rest in
      let common =
        List.fold_left
          (fun acc l -> if l = "" then acc else min acc (indent_of l))
          max_int rest
      in
      let common = if common = max_int then 0 else common in
      let rest =
        List.map (fun l -> if l = "" then "" else String.sub l common (String.length l - common)) rest
      in
      rstrip (String.trim first) :: rest
  in
  match drop_blank_ends lines with
  | [] -> [ indent ^ "--" ]
  | ls -> List.map (fun l -> rstrip (indent ^ "-- " ^ l)) ls

let to_line_comments (src : string) : string =
  let starts =
    Lexer.tokenize src
    |> List.filter_map (fun (tok, (loc : Token.loc)) ->
           match tok with
           | Token.Comment _ | Token.DocComment _ -> Some loc.Token.offset
           | _ -> None)
  in
  let buf = Buffer.create (String.length src) in
  let cursor = ref 0 in
  List.iter
    (fun start ->
      (* A comment inside another one is already part of the outer comment's
         text; the lexer does not report it, so nothing here has to skip it.
         A start behind the cursor would mean exactly that, and is ignored. *)
      if start >= !cursor then begin
        let stop = comment_end src start in
        let n = String.length src in
        let ls = line_start src start in
        let before = String.sub src ls (start - ls) in
        let after_end =
          let e = ref stop in
          while !e < n && src.[!e] <> '\n' do incr e done;
          String.sub src stop (!e - stop)
        in
        let inner =
          let body = String.sub src (start + 2) (stop - start - 4) in
          (* A doc comment opens with an extra star, which is the
             marker and not the prose. *)
          if String.length body > 0 && body.[0] = '*' then
            String.sub body 1 (String.length body - 1)
          else body
        in
        Buffer.add_string buf (String.sub src !cursor (start - !cursor));
        if not (is_blank after_end) then
          (* Code follows on this line, so `--` would swallow it. *)
          Buffer.add_string buf (String.sub src start (stop - start))
        else begin
          let indent = if is_blank before then before else String.make (String.length before) ' ' in
          let lines = render indent inner in
          let text = String.concat "\n" lines in
          (* After code on the same line, the first `--` follows it and the
             rest go under it. *)
          if is_blank before then Buffer.add_string buf text
          else
            Buffer.add_string buf
              (String.concat "\n"
                 (List.mapi (fun i l -> if i = 0 then String.trim l else l) lines))
        end;
        cursor := stop
      end)
    starts;
  Buffer.add_string buf (String.sub src !cursor (String.length src - !cursor));
  Buffer.contents buf
