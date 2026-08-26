(* The property phase 1 checks: `wand t` on any input at all answers with a
   diagnostic, and never any other way.

   `Runner.typecheck_source` catches `LexError`, `ParseError`, `TypeError`,
   `TypeErrorAt` and `Failure`, and turns each into a `Diag.t`. Anything
   else escaping it reaches a user as an OCaml backtrace, which is a crash
   however it is spelled. So the oracle is: `Ok` or `Error` is a pass;
   escaping, overflowing or hanging is a finding.

   `Failure` gets its own verdict rather than counting as a pass. It is
   caught, but it is caught at the top of the pipeline with no position and
   no code of its own -- an `index out of bounds` from the lexer and a
   deliberate `failwith` in the typechecker both arrive as `E-FAIL`. The
   ones that are internal errors wearing a diagnostic's clothes are worth
   seeing, so they are reported separately and can be listed in known.txt
   like anything else. *)

open Wand

type verdict =
  | Skipped                      (* not this oracle's business *)
  | Typed of string              (* Ok: the input typechecked, to this type *)
  | Rejected of string           (* Error: a diagnostic, with its code *)
  | Internal of string           (* E-FAIL: a `Failure` from inside a stage *)
  | Crash    of string * string  (* an exception escaped: signature, backtrace *)
  | Overflow                     (* Stack_overflow *)
  | Timeout                      (* did not finish inside the budget *)
  | Died     of string           (* the process itself did not survive *)
  (* ── The formatter ────────────────────────────────────────────────────── *)
  | FmtUnparses  of string       (* `wand f` wrote source that does not parse *)
  | FmtUnstable                  (* a second pass changed it again *)
  | FmtLostComment               (* a comment did not survive the round trip *)
  | FmtRetyped   of string       (* it means something else afterwards *)
  | FmtCrash     of string * string
  (* A verdict reached in another process, carried back whole. The child has
     already computed the signature and the description, so nothing here has
     to reconstruct a verdict from its own output -- which was a parser for
     a format this file both writes and reads, and would have to grow a case
     for every constructor above. *)
  | Reported of { sg : string; desc : string; bt : string }

exception Timed_out

let is_finding = function
  | Skipped | Typed _ | Rejected _ -> false
  | Internal _ | Crash _ | Overflow | Timeout | Died _ -> true
  | FmtUnparses _ | FmtUnstable | FmtLostComment | FmtRetyped _ | FmtCrash _ -> true
  (* A child reports whatever it reached, pass or finding. An empty
     signature is how it says "nothing wrong", so that is what decides. *)
  | Reported r -> r.sg <> ""

(* Digits, quoted text and file paths are the parts of a message that vary
   between two arrivals of one bug, so they come out of the signature. Two
   findings that normalise to the same string are one finding.

   Paths matter most: an unreadable import reports the path it tried, so
   without this one bug arrives once per name the mutations invent, and a
   report of thirty findings is a report of one. *)
let collapse_paths msg =
  msg
  |> String.map (fun c -> if c = '\n' || c = '\t' || c = '\r' then ' ' else c)
  |> String.split_on_char ' '
  |> List.map (fun tok -> if String.contains tok '/' then "<path>" else tok)
  |> String.concat " "

let normalise msg =
  let msg = collapse_paths msg in
  let b = Buffer.create (String.length msg) in
  let in_quote = ref false and last_digit = ref false in
  String.iter (fun c ->
    if c = '"' || c = '\'' then begin
      if not !in_quote then Buffer.add_char b '_';
      in_quote := not !in_quote
    end else if !in_quote then ()
    else if c >= '0' && c <= '9' then begin
      if not !last_digit then Buffer.add_char b 'N';
      last_digit := true
    end else begin
      last_digit := false;
      Buffer.add_char b (if c = '\n' then ' ' else c)
    end) msg;
  let s = Buffer.contents b in
  (* Trimmed after the cut, not before: the cut lands mid-message and often
     on a space, and a signature with a trailing space cannot be written on
     a line of known.txt. *)
  String.trim (if String.length s > 80 then String.sub s 0 80 else s)

(* The first frame that carries a source location. `Printexc.to_string`
   alone puts every `Not_found` in one bucket; the frame is what separates
   the lexer's from the parser's. *)
let frame_of raw =
  match Printexc.backtrace_slots raw with
  | None -> "?"
  | Some slots ->
    let rec go i =
      if i >= Array.length slots then "?"
      else match Printexc.Slot.location slots.(i) with
        | Some l -> Printf.sprintf "%s:%d" l.Printexc.filename l.Printexc.line_number
        | None -> go (i + 1)
    in
    go 0

let signature = function
  | Skipped -> None
  | Typed _ -> None
  | Rejected _ -> None
  (* The parse error's text is not in the signature. It is a property of the
     input, not of the bug: four mutants produced four messages for what is
     one broken claim -- that formatting source produces source. Four lines
     in known.txt for one bug is a report nobody can read, and the message
     is still in the finding's own notes where a reader needs it. *)
  | FmtUnparses _ -> Some "format:unparses"
  | FmtUnstable -> Some "format:unstable"
  | FmtLostComment -> Some "format:lost-comment"
  | FmtRetyped what -> Some ("format:retyped:" ^ normalise what)
  | FmtCrash (sg, _) -> Some ("format:crash:" ^ sg)
  | Reported r -> if r.sg = "" then None else Some r.sg
  | Internal msg -> Some ("internal:" ^ normalise msg)
  | Crash (sg, _) -> Some ("crash:" ^ sg)
  | Overflow -> Some "overflow:Stack_overflow"
  | Timeout -> Some "timeout"
  | Died how -> Some ("died:" ^ how)

let describe = function
  | Skipped -> "not checked"
  | Typed t -> "typechecked (" ^ t ^ ")"
  | Rejected code -> "rejected (" ^ code ^ ")"
  | FmtUnparses msg -> "wand f wrote source that does not parse: " ^ normalise msg
  | FmtUnstable -> "wand f is not idempotent here"
  | FmtLostComment -> "wand f dropped or restyled a comment"
  | FmtRetyped what -> "wand f changed what the file means: " ^ what
  | FmtCrash (sg, _) -> "wand f raised: " ^ sg
  | Reported r -> r.desc
  | Internal msg -> "E-FAIL: " ^ normalise msg
  | Crash (sg, _) -> "escaped: " ^ sg
  | Overflow -> "stack overflow"
  | Timeout -> "timed out"
  | Died how -> "process died: " ^ how

let backtrace_of = function
  | Crash (_, bt) | FmtCrash (_, bt) -> bt
  | Reported r -> r.bt
  | _ -> ""

(* A file name a finding can be written to. *)
let slug sg =
  String.map (fun c ->
    if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
       || (c >= '0' && c <= '9') || c = '-' || c = '.'
    then c else '-') sg

(* ── Running one input ────────────────────────────────────────────────────── *)

let with_timeout secs f =
  let previous = Sys.signal Sys.sigalrm (Sys.Signal_handle (fun _ -> raise Timed_out)) in
  let disarm () =
    ignore (Unix.setitimer Unix.ITIMER_REAL
              { Unix.it_value = 0.; it_interval = 0. });
    Sys.set_signal Sys.sigalrm previous
  in
  ignore (Unix.setitimer Unix.ITIMER_REAL { Unix.it_value = secs; it_interval = 0. });
  match f () with
  | v -> disarm (); v
  | exception e ->
    let raw = Printexc.get_raw_backtrace () in
    disarm ();
    Printexc.raise_with_backtrace e raw

(* `path` is the name the input is typechecked under. It decides the base
   environment (stdlib files get `stdlib_type_env`) and the directory
   imports resolve against, so a mutant of a stdlib module is checked the
   way that module is. *)
let check ?(timeout = 10.0) ~path src =
  try
    with_timeout timeout (fun () ->
      match Runner.typecheck_source ~path src with
      | Ok sc -> Typed sc.Runner.sc_type
      | Error d when d.Diag.code = "E-FAIL" -> Internal d.Diag.message
      | Error d -> Rejected d.Diag.code)
  with
  | Timed_out -> Timeout
  | Stack_overflow -> Overflow
  | e ->
    let raw = Printexc.get_raw_backtrace () in
    Crash (Printexc.to_string e ^ "@" ^ frame_of raw, Printexc.raw_backtrace_to_string raw)

(* ── The formatter ────────────────────────────────────────────────────────── *)

(* `wand f` is a fixed point on the tree, and `test_formatter.ml` holds that:
   every file in the stdlib formats to itself. What nothing held is the same
   claim about source nobody wrote. The formatter has produced source that
   does not parse before -- it is written down in CLAUDE.md, as the reason a
   formatter change is verified differently from any other change -- and a
   corpus that is already a fixed point cannot find that again.

   Four properties, on any input that parses:

     it parses     formatting produces source the parser accepts
     it settles    a second pass changes nothing the first did not
     it remembers  every comment survives, unedited
     it means it   the file still typechecks to what it typechecked to

   The last one is not implied by the others. The formatter sorts the leading
   import block, and an import decides what a name refers to, so a reordering
   that is wrong is a reordering that changes the program while leaving it
   perfectly parseable and perfectly stable.

   The margin varies per input. A layout bug is a bug about what fits, and a
   margin that is always 92 tests one column and calls it the formatter. *)

(* Trailing whitespace comes off before comparing. A formatter is supposed
   to remove it -- it is invisible, and leaving it is how a file ends up with
   a diff nobody meant. Keeping it in the comparison made the oracle report
   `-- Return true ` becoming `-- Return true` as a lost comment, which is
   the formatter doing its job. Leading space is left alone: the space after
   `--` is style the formatter must not touch. *)
let rstrip s =
  let n = ref (String.length s) in
  while !n > 0 && (match s.[!n - 1] with ' ' | '\t' | '\r' -> true | _ -> false) do
    decr n
  done;
  String.sub s 0 !n

let comments_of src =
  let tokens = Lexer.tokenize src in
  List.sort compare
    (List.map (fun (c : Formatter.comment_tok) -> rstrip c.Formatter.c_text)
       (Formatter.all_comments src tokens))

let parses src =
  match Parser.parse_program (Lexer.tokenize src) with
  | _ -> true
  | exception _ -> false

let check_format ?(timeout = 10.0) ~width ~path ~before src =
  (* Source that does not parse is the other oracle's business. *)
  if not (parses src) then Skipped
  else
    try
      with_timeout timeout (fun () ->
        let fmt s = Formatter.with_width width (fun () -> Formatter.format_source s) in
        let once = fmt src in
        if not (parses once) then
          FmtUnparses
            (match Runner.typecheck_source ~path once with
             | Error d -> d.Diag.message
             | Ok _ -> "the parser refused it, and then did not")
        else if fmt once <> once then FmtUnstable
        else if comments_of once <> comments_of src then FmtLostComment
        else
          match before, Runner.typecheck_source ~path once with
          | Typed was, Ok sc when sc.Runner.sc_type <> was ->
            FmtRetyped (Printf.sprintf "was %s, now %s" was sc.Runner.sc_type)
          | Typed was, Error d ->
            FmtRetyped (Printf.sprintf "was %s, now %s" was d.Diag.code)
          | Rejected was, Ok sc ->
            FmtRetyped (Printf.sprintf "was %s, now typechecks to %s" was sc.Runner.sc_type)
          | Rejected was, Error d when d.Diag.code <> was ->
            FmtRetyped (Printf.sprintf "was %s, now %s" was d.Diag.code)
          | _ -> Skipped)
    with
    | Timed_out -> Timeout
    | Stack_overflow -> Overflow
    | e ->
      let raw = Printexc.get_raw_backtrace () in
      FmtCrash (Printexc.to_string e ^ "@" ^ frame_of raw,
                Printexc.raw_backtrace_to_string raw)

(* What the formatter did to one input, for a person reading a finding. A
   format finding says a property broke; it does not say what came out, and
   what came out is the whole of what a reader needs. *)
let explain ~width ~path src =
  let fmt s = Formatter.with_width width (fun () -> Formatter.format_source s) in
  let show label text =
    Printf.printf "── %s ──\n%s\n" label text
  in
  show "input" src;
  match fmt src with
  | exception e -> Printf.printf "wand f raised: %s\n" (Printexc.to_string e)
  | once ->
    show "formatted once" once;
    (match fmt once with
     | exception e -> Printf.printf "the second pass raised: %s\n" (Printexc.to_string e)
     | twice ->
       if twice <> once then show "formatted twice (differs)" twice
       else print_endline "── formatted twice: unchanged ──");
    let before = try comments_of src with _ -> ["<unlexable>"] in
    let after  = try comments_of once with _ -> ["<unlexable>"] in
    if before <> after then begin
      Printf.printf "── comments before (%d) ──\n%s\n" (List.length before)
        (String.concat "\n" (List.map (Printf.sprintf "%S") before));
      Printf.printf "── comments after (%d) ──\n%s\n" (List.length after)
        (String.concat "\n" (List.map (Printf.sprintf "%S") after))
    end else Printf.printf "── comments: %d, unchanged ──\n" (List.length before);
    (match Runner.typecheck_source ~path src, Runner.typecheck_source ~path once with
     | Ok a, Ok b -> Printf.printf "── type: %s -> %s ──\n" a.Runner.sc_type b.Runner.sc_type
     | Ok a, Error d -> Printf.printf "── type: %s -> %s ──\n" a.Runner.sc_type d.Diag.code
     | Error d, Ok b -> Printf.printf "── type: %s -> %s ──\n" d.Diag.code b.Runner.sc_type
     | Error a, Error b -> Printf.printf "── type: %s -> %s ──\n" a.Diag.code b.Diag.code)

(* Both properties, in the order that costs least: the typecheck oracle
   first, and the formatter only on input it did not already condemn. The
   first verdict is handed to the second, so an input is typechecked twice
   and not three times. *)
let check_all ?(timeout = 10.0) ~width ~path src =
  let v = check ~timeout ~path src in
  if is_finding v then v
  else
    match check_format ~timeout ~width ~path ~before:v src with
    (* The formatter had nothing to say, so the input is still whatever the
       typecheck made of it. Returning `Skipped` here threw that away and
       reported every input in one bucket. *)
    | Skipped -> v
    | f -> f

(* ── Running one input in a process of its own ────────────────────────────── *)

(* The loop above reuses one process for speed, and the pipeline has globals
   (`Typechecker.local_binders`, the import cache). An input that crashes
   only because a previous input left something behind is not a bug in that
   input, and filing it would teach a reader to distrust the whole report.
   So every finding is re-run here, in a process that has typechecked
   nothing, and only what reproduces is filed.

   It also catches what an exception handler cannot: a segfault from the C
   stubs, or a hang the alarm does not interrupt. *)
let check_in_child ?(timeout = 10.0) ~width ~path src =
  (* Whatever this process has buffered and not written belongs to it alone.
     A fork copies the buffer, and the child flushes its copy when it exits,
     so anything printed before this line would appear twice. *)
  flush stdout;
  flush stderr;
  let (r, w) = Unix.pipe ~cloexec:false () in
  match Unix.fork () with
  | 0 ->
    Unix.close r;
    let v = try check_all ~timeout ~width ~path src with e -> Died (Printexc.to_string e) in
    (* signature, description and backtrace, one per record, newlines in the
       backtrace escaped so the three can be split apart again. *)
    let payload =
      String.concat "\x1e"
        [ (match signature v with None -> "" | Some sg -> sg);
          describe v;
          String.concat "\x1f" (String.split_on_char '\n' (backtrace_of v)) ]
    in
    let b = Bytes.of_string payload in
    (try ignore (Unix.write w b 0 (Bytes.length b)) with _ -> ());
    Unix.close w;
    Stdlib.exit 0
  | child ->
    Unix.close w;
    let buf = Buffer.create 4096 in
    let chunk = Bytes.create 4096 in
    let rec drain () =
      match Unix.read r chunk 0 4096 with
      | 0 -> ()
      | n -> Buffer.add_subbytes buf chunk 0 n; drain ()
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> drain ()
    in
    drain ();
    Unix.close r;
    let (_, status) = Unix.waitpid [] child in
    let payload = Buffer.contents buf in
    (match status with
     | Unix.WEXITED 0 ->
       (match String.split_on_char '\x1e' payload with
        | [sg; desc; bt] ->
          Reported { sg; desc;
                     bt = String.concat "\n" (String.split_on_char '\x1f' bt) }
        | _ -> Died ("unreadable child payload: " ^ payload))
     | Unix.WEXITED n -> Died (Printf.sprintf "exit %d" n)
     | Unix.WSIGNALED n -> Died (Printf.sprintf "signal %d" n)
     | Unix.WSTOPPED n -> Died (Printf.sprintf "stopped %d" n))
