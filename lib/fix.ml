(* `wand t --fix`: apply the corrections the checker already computes,
   re-check, and repeat to a fixed point -- a fix can unlock a further
   finding. One fix representation, two consumers: this engine for the
   CLI's generate/typecheck loop, `codeAction` for the human in the
   editor. A fix that behaves differently in the two paths is a bug.

   The textual drift corrections (`Diag.Replace`) are deliberately not
   applied: they annotate lex and parse errors, and rewriting a file that
   does not parse is guesswork. An error carrying no applicable fix
   refuses the whole run -- nothing is written. *)

type applied = {
  code : string;    (* "A-USES2", "V-IMP1", "E-TYPE", ... *)
  line : int;       (* the 1-based line it changed, in the file as it was *)
  note : string;    (* what changed, for the per-fix report *)
  diag : Diag.t;    (* the diagnostic it answered, for --json *)
}

(* Lines are 1-based. Splitting on '\n' keeps a final empty piece for a
   trailing newline, so joining restores the file byte for byte. *)
let split_lines = String.split_on_char '\n'
let join_lines = String.concat "\n"

let is_shebang = function
  | first :: _ -> String.length first >= 2 && first.[0] = '#' && first.[1] = '!'
  | [] -> false

let is_manifest_text s =
  let t = String.trim s in
  String.length t > 4 && String.sub t 0 4 = "uses"
  && String.trim (String.sub t 4 (String.length t - 4)) <> ""
  && (String.trim (String.sub t 4 (String.length t - 4))).[0] = '{'

(* Replace the 1-based line [n]. *)
let replace_line lines n text =
  List.mapi (fun i l -> if i = n - 1 then text else l) lines

let delete_line lines n =
  List.filteri (fun i _ -> i <> n - 1) lines

(* The line a manifest correction lands on. The diagnostic usually points
   there already (A-USES1, the manifest type error); a shell-word error
   points at the $() that tripped it, so the manifest is found by looking. *)
let manifest_line lines =
  let rec go i = function
    | [] -> None
    | l :: rest -> if is_manifest_text l then Some (i + 1) else go (i + 1) rest
  in
  go 0 lines

let quote s = "\"" ^ String.trim s ^ "\""

(* Apply one fix, answering the new lines and what happened -- or None when
   the fix is not one this engine applies. *)
let apply_fix lines (d : Diag.t) : (string list * applied) option =
  let loc_line = match d.Diag.loc with Some l -> l.Token.line | None -> 1 in
  let at line note lines' =
    Some (lines', { code = d.Diag.code; line; note; diag = d })
  in
  match d.Diag.fix with
  | Some (Diag.InsertLine text) ->
    (* Manifest creation: the manifest is the first thing in the file,
       after a shebang if one is there. *)
    let n = if is_shebang lines then 2 else 1 in
    let before = List.filteri (fun i _ -> i < n - 1) lines in
    let after  = List.filteri (fun i _ -> i >= n - 1) lines in
    at n ("inserted " ^ quote text) (before @ [text] @ after)
  | Some (Diag.ReplaceLine text) ->
    let n =
      if is_manifest_text text then
        match manifest_line lines with Some n -> n | None -> loc_line
      else loc_line
    in
    (match List.nth_opt lines (n - 1) with
     | Some old when old <> text ->
       at n ("replaced " ^ quote old ^ " with " ^ quote text)
         (replace_line lines n text)
     | _ -> None)
  | Some Diag.DeleteLine ->
    (match List.nth_opt lines (loc_line - 1) with
     | Some old -> at loc_line ("deleted " ^ quote old) (delete_line lines loc_line)
     | None -> None)
  | Some (Diag.Replace _) | None -> None

(* One pass over a clean check's findings, bottom-up so earlier line
   numbers stay valid, at most one fix per line -- overlapping fixes wait
   for the next pass, which re-checks first. *)
let apply_findings lines (diags : Diag.t list) =
  let fixable = List.filter (fun d -> d.Diag.fix <> None) diags in
  let line_of d = match d.Diag.loc with Some l -> l.Token.line | None -> 1 in
  let sorted = List.stable_sort (fun a b -> compare (line_of b) (line_of a)) fixable in
  let (lines, applied, _) =
    List.fold_left (fun (lines, acc, seen) d ->
      let n = line_of d in
      if List.mem n seen then (lines, acc, seen)
      else
        match apply_fix lines d with
        | Some (lines', a) -> (lines', a :: acc, n :: seen)
        | None -> (lines, acc, seen)
    ) (lines, [], []) sorted
  in
  (lines, List.rev applied)

(* A fix can unlock a further finding, so the loop re-checks after every
   pass; the cap only guards against a fix that fails to converge, which
   would be a bug in the fix itself. *)
let max_passes = 5

let fix_source ~path (src : string) : (string * applied list, Diag.t) result =
  let rec go lines applied passes =
    if passes = 0 then Ok (join_lines lines, List.rev applied)
    else
      match Runner.typecheck_source ~path (join_lines lines) with
      | Error d ->
        (match apply_fix lines d with
         | Some (lines', a) -> go lines' (a :: applied) (passes - 1)
         | None ->
           (* An error this engine cannot correct: refuse, keeping the
              file exactly as it was -- even fixes from earlier passes
              are abandoned rather than written around a broken state. *)
           Error d)
      | Ok sc ->
        let diags =
          List.map (Lint.to_diag ~strict:false) sc.Runner.sc_findings in
        (match apply_findings lines diags with
         | (_, []) -> Ok (join_lines lines, List.rev applied)
         | (lines', pass) -> go lines' (List.rev_append pass applied) (passes - 1))
  in
  go (split_lines src) [] max_passes

(* In place, like `wand f`. Nothing is written when nothing changed or
   when the engine refuses. *)
let fix_file path : (applied list, Diag.t) result =
  let full =
    if Filename.is_relative path
    then Filename.concat (Sys.getcwd ()) path
    else path
  in
  match In_channel.with_open_text full In_channel.input_all with
  | exception Sys_error msg ->
    Error (Diag.error ~code:"E-FAIL" ("cannot open file: " ^ msg))
  | src ->
    match fix_source ~path src with
    | Error d -> Error d
    | Ok (fixed, applied) ->
      if fixed <> src then
        Out_channel.with_open_text full (fun oc ->
          Out_channel.output_string oc fixed);
      Ok applied
