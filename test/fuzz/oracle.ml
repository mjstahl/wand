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
  | Typed                        (* Ok: the input typechecked *)
  | Rejected of string           (* Error: a diagnostic, with its code *)
  | Internal of string           (* E-FAIL: a `Failure` from inside a stage *)
  | Crash    of string * string  (* an exception escaped: signature, backtrace *)
  | Overflow                     (* Stack_overflow *)
  | Timeout                      (* did not finish inside the budget *)
  | Died     of string           (* the process itself did not survive *)

exception Timed_out

let is_finding = function
  | Typed | Rejected _ -> false
  | Internal _ | Crash _ | Overflow | Timeout | Died _ -> true

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
  | Typed -> None
  | Rejected _ -> None
  | Internal msg -> Some ("internal:" ^ normalise msg)
  | Crash (sg, _) -> Some ("crash:" ^ sg)
  | Overflow -> Some "overflow:Stack_overflow"
  | Timeout -> Some "timeout"
  | Died how -> Some ("died:" ^ how)

let describe = function
  | Typed -> "typechecked"
  | Rejected code -> "rejected (" ^ code ^ ")"
  | Internal msg -> "E-FAIL: " ^ normalise msg
  | Crash (sg, _) -> "escaped: " ^ sg
  | Overflow -> "stack overflow"
  | Timeout -> "timed out"
  | Died how -> "process died: " ^ how

let backtrace_of = function Crash (_, bt) -> bt | _ -> ""

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
      | Ok _ -> Typed
      | Error d when d.Diag.code = "E-FAIL" -> Internal d.Diag.message
      | Error d -> Rejected d.Diag.code)
  with
  | Timed_out -> Timeout
  | Stack_overflow -> Overflow
  | e ->
    let raw = Printexc.get_raw_backtrace () in
    Crash (Printexc.to_string e ^ "@" ^ frame_of raw, Printexc.raw_backtrace_to_string raw)

(* ── Running one input in a process of its own ────────────────────────────── *)

(* The loop above reuses one process for speed, and the pipeline has globals
   (`Typechecker.local_binders`, the import cache). An input that crashes
   only because a previous input left something behind is not a bug in that
   input, and filing it would teach a reader to distrust the whole report.
   So every finding is re-run here, in a process that has typechecked
   nothing, and only what reproduces is filed.

   It also catches what an exception handler cannot: a segfault from the C
   stubs, or a hang the alarm does not interrupt. *)
let check_in_child ?(timeout = 10.0) ~path src =
  let (r, w) = Unix.pipe ~cloexec:false () in
  match Unix.fork () with
  | 0 ->
    Unix.close r;
    let v = try check ~timeout ~path src with _ -> Died "child raised" in
    let payload = match signature v with None -> "" | Some s -> s in
    let payload = (match v with Crash (_, bt) -> payload ^ "\n" ^ bt | _ -> payload) in
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
    let (sg, bt) =
      match String.index_opt payload '\n' with
      | Some i -> (String.sub payload 0 i,
                   String.sub payload (i + 1) (String.length payload - i - 1))
      | None -> (payload, "")
    in
    (match status with
     | Unix.WEXITED 0 when sg = "" -> Typed          (* or Rejected: a pass either way *)
     | Unix.WEXITED 0 ->
       if sg = "overflow:Stack_overflow" then Overflow
       else if sg = "timeout" then Timeout
       else if String.length sg > 9 && String.sub sg 0 9 = "internal:" then
         Internal (String.sub sg 9 (String.length sg - 9))
       else if String.length sg > 6 && String.sub sg 0 6 = "crash:" then
         Crash (String.sub sg 6 (String.length sg - 6), bt)
       else Died sg
     | Unix.WEXITED n -> Died (Printf.sprintf "exit %d" n)
     | Unix.WSIGNALED n -> Died (Printf.sprintf "signal %d" n)
     | Unix.WSTOPPED n -> Died (Printf.sprintf "stopped %d" n))
