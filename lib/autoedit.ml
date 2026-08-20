(* The editor's lexical tier (LSP.md §2.1): edits provable from the token
   stream alone. When a change completes a qualified name `N.member` --
   `List.map!` followed by a space, a paren, a newline -- and N is an
   unimported standard library module with that member, the fix is
   unambiguous without inference: insert `import N`, and put the member's
   manifest-relevant labels into `uses {...}` if the file has one.

   Deliberate limits, each load-bearing (the design spells out why):
   - fires only when the member resolves; a miss gets a diagnostic, never
     a guessed edit;
   - the `Shell` label is never added, removed, or widened here -- Shell
     changes go through the visible code action, though the import itself
     still lands;
   - a manifest is extended, never created;
   - stdlib modules only, matched by exact name.

   Everything is a pure function of buffer text, so the tests feed text in
   and read edits out; the server turns the edits into workspace/applyEdit,
   and completion reuses `edits_for_member` as additionalTextEdits. *)

type edit =
  | Insert_line of int * string   (* insert as a new line before 1-based line n *)
  | Replace_line of int * string  (* replace 1-based line n *)

(* A buffer mid-keystroke can fail to lex (an unterminated string, say);
   then there is nothing to act on, which is the right answer -- the cursor
   is somewhere an edit should not fire from anyway. *)
let tokens_of text =
  match Lexer.tokenize text with
  | toks -> toks
  | exception _ -> []

let is_ident_continuation = function
  | 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' | '!' | '?' -> true
  | _ -> false

(* Every *completed* qualified reference in the text: `N.member` written
   with no interior space, whose next character exists and is not part of a
   longer name (nor a `.` continuing a chain). Comment tokens are skipped;
   string and command interpolations never surface as Ident tokens, so
   nothing inside them can trigger. *)
let qualified_refs text : (string * string) list =
  let n = String.length text in
  let toks =
    List.filter (fun (t, _) ->
      match t with
      | Token.Comment _ | Token.LineComment _ | Token.DocComment _ -> false
      | _ -> true)
      (tokens_of text)
  in
  let rec go acc = function
    | (Token.Upper ns, (l1 : Token.loc))
      :: (Token.Dot, (l2 : Token.loc))
      :: (Token.Ident m, (l3 : Token.loc)) :: rest
      when l1.Token.end_offset = l2.Token.offset
        && l2.Token.end_offset = l3.Token.offset ->
      let completed =
        l3.Token.end_offset < n
        && (let c = text.[l3.Token.end_offset] in
            not (is_ident_continuation c) && c <> '.')
      in
      go (if completed && not (List.mem (ns, m) acc) then (ns, m) :: acc else acc) rest
    | _ :: rest -> go acc rest
    | [] -> List.rev acc
  in
  go [] toks

(* The namespace names the buffer already binds. `import N` binds N; a
   let-bound import (`let x = import FS`) is counted too, conservatively --
   the module is in play under another name, and this tier only ever
   declines when unsure. *)
let bound_namespaces toks =
  let rec go acc = function
    | (Token.Import, _) :: (Token.Upper n, _) :: rest -> go (n :: acc) rest
    | _ :: rest -> go acc rest
    | [] -> acc
  in
  go [] toks

(* ── The import block ────────────────────────────────────────────────────── *)

let is_blank s = String.trim s = ""

let is_comment_line s =
  let t = String.trim s in
  (String.length t >= 2 && String.sub t 0 2 = "--")
  || (String.length t >= 2 && String.sub t 0 2 = "(*")

(* A plain `import M` line, answering M. *)
let plain_import_of line =
  let t = String.trim line in
  let kw = "import " in
  if String.length t <= String.length kw
     || String.sub t 0 (String.length kw) <> kw
  then None
  else
    let rest = String.trim (String.sub t (String.length kw)
                              (String.length t - String.length kw)) in
    let len =
      let i = ref 0 in
      while !i < String.length rest && is_ident_continuation rest.[!i] do incr i done;
      !i
    in
    if len = 0 then None
    else
      let name = String.sub rest 0 len in
      let tail = String.trim (String.sub rest len (String.length rest - len)) in
      let only_comment =
        tail = "" || (String.length tail >= 2 && String.sub tail 0 2 = "--")
      in
      if only_comment && name.[0] >= 'A' && name.[0] <= 'Z' then Some name
      else None

let is_shebang_line s = String.length s >= 2 && s.[0] = '#' && s.[1] = '!'

(* Where `import ns` goes: into the contiguous block of plain imports at the
   top of the file, at the position that keeps a sorted block sorted (an
   unsorted block gets the least-wrong position -- after the last line that
   sorts before it). With no block, the line lands where the block
   canonically starts: after the manifest and the blank line that follows
   it, after a shebang, else at the top. Existing lines are never moved. *)
let import_insertion ~ns lines : edit =
  let arr = Array.of_list lines in
  let len = Array.length arr in
  let rec find_block i =
    if i >= len then None
    else
      let l = arr.(i) in
      if (i = 0 && is_shebang_line l)
         || Fix.is_manifest_text l || is_blank l || is_comment_line l
      then find_block (i + 1)
      else if plain_import_of l <> None then Some i
      else None
  in
  match find_block 0 with
  | Some start ->
    let rec place i =
      if i >= len then i
      else match plain_import_of arr.(i) with
        | Some m when m < ns -> place (i + 1)
        | Some _ -> i
        | None -> i
    in
    Insert_line (place start + 1, "import " ^ ns)
  | None ->
    let after_manifest =
      match Fix.manifest_line lines with
      | Some m -> if m < len && is_blank arr.(m) then Some (m + 2) else Some (m + 1)
      | None -> None
    in
    let n = match after_manifest with
      | Some n -> n
      | None -> if len > 0 && is_shebang_line arr.(0) then 2 else 1
    in
    Insert_line (n, "import " ^ ns)

(* ── The manifest ────────────────────────────────────────────────────────── *)

(* The labels a single-line manifest declares, read by the real parser on
   that line alone. A manifest this cannot read -- wrapped across lines, or
   mid-edit -- declines the extension; the checked tier still reports what
   the manifest should say. *)
let manifest_labels_of_line line : (string * string list option) list option =
  match Parser.parse_program (Lexer.tokenize line) with
  | { Ast.manifest = Some (labels, _); _ } -> Some labels
  | _ -> None
  | exception _ -> None

(* Extend `uses {...}` with the labels the completed members commit the file
   to, rendered in the canonical form (sorted labels, `Shell` binaries kept
   exactly as written -- this tier never touches Shell). Text after the
   closing brace, a trailing comment, survives. *)
let extend_manifest ~labels lines : edit option =
  let labels = List.filter (fun l -> l <> "Shell") labels in
  match Fix.manifest_line lines with
  | None -> None                                  (* never create one *)
  | Some n ->
    let line = List.nth lines (n - 1) in
    (match manifest_labels_of_line line with
     | None -> None
     | Some entries ->
       let have = List.map fst entries in
       let missing = List.filter (fun l -> not (List.mem l have)) labels in
       if missing = [] then None
       else
         let entries =
           List.sort (fun (a, _) (b, _) -> compare a b)
             (entries @ List.map (fun l -> (l, None)) missing)
         in
         let rendered =
           "uses {"
           ^ String.concat ", " (List.map Shell_scan.render_label entries)
           ^ "}"
         in
         let suffix =
           match String.rindex_opt line '}' with
           | Some i -> String.sub line (i + 1) (String.length line - i - 1)
           | None -> ""
         in
         let text = rendered ^ suffix in
         if text = line then None else Some (Replace_line (n, text)))

(* ── Entry points ────────────────────────────────────────────────────────── *)

(* `sig_of` answers a stdlib module's exported signature -- in production
   `Runner.stdlib_module_sig`, in tests whatever the test says. *)
let edits_for ~sig_of ~text refs : edit list =
  let bound = bound_namespaces (tokens_of text) in
  let usable =
    List.filter_map (fun (ns, m) ->
      if List.mem ns bound then None
      else
        match sig_of ns with
        | None -> None
        | Some (env, _docs) ->
          (match List.assoc_opt m env with
           | Some scheme -> Some (ns, scheme)
           | None -> None))
      refs
  in
  let lines = Fix.split_lines text in
  let nss = List.sort_uniq compare (List.map fst usable) in
  let imports = List.map (fun ns -> import_insertion ~ns lines) nss in
  let labels =
    List.sort_uniq compare
      (List.concat_map (fun (_, scheme) ->
         List.map Effect_set.name_of
           (Effect_set.EffSet.elements
              (Typechecker.manifest_labels_of_scheme scheme)))
         usable)
  in
  imports @ Option.to_list (extend_manifest ~labels lines)

(* What a change newly completed: qualified references present now that were
   not present before. An undo that removes an inserted import removes no
   reference, so nothing re-fires against the author's decision. *)
let changes ~sig_of ~old_text text : edit list =
  let old_refs = qualified_refs old_text in
  let refs =
    List.filter (fun r -> not (List.mem r old_refs)) (qualified_refs text)
  in
  if refs = [] then [] else edits_for ~sig_of ~text refs

(* Completion's half of the same bargain: accepting `N.member` from the list
   carries exactly the edits typing it would have earned. *)
let edits_for_member ~sig_of ~text ns member : edit list =
  edits_for ~sig_of ~text [(ns, member)]
