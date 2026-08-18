(* The wand language server: LSP over stdio, which is Content-Length
   framing plus JSON-RPC. Hand-rolled over yojson on purpose -- the v1
   surface is a handful of methods, and the opam `lsp` package would be
   the largest dependency in the tree, moving with ocaml-lsp's needs
   rather than ours (LSP.md §1).

   One loop, single-threaded: read a message, handle it, write what it
   produced. Every answer costs milliseconds (the whole buffer is
   re-checked per change; wand files are small), so there is no request
   queue and no cancellation machinery.

   `handle` is the whole protocol as a function -- state and one incoming
   message to new state and outgoing messages -- so the tests feed it
   parsed JSON directly; `serve` is only the stdio instantiation. *)

module J = Yojson.Safe

(* ── JSON access, total ──────────────────────────────────────────────────── *)

let mem k = function
  | `Assoc l -> (match List.assoc_opt k l with Some v -> v | None -> `Null)
  | _ -> `Null

let str = function `String s -> Some s | _ -> None

(* ── Framing ─────────────────────────────────────────────────────────────── *)

(* Header lines arrive "\r\n"-terminated; `input_line` leaves the '\r'. *)
let trim_cr s =
  let n = String.length s in
  if n > 0 && s.[n - 1] = '\r' then String.sub s 0 (n - 1) else s

let content_length_of line =
  let lower = String.lowercase_ascii line in
  let prefix = "content-length:" in
  if String.length lower >= String.length prefix
     && String.sub lower 0 (String.length prefix) = prefix
  then
    int_of_string_opt
      (String.trim
         (String.sub line (String.length prefix)
            (String.length line - String.length prefix)))
  else None

(* One framed message, or None when the stream has ended (or stopped making
   sense -- a transport that has lost framing cannot be resynchronized). *)
let read_message ic : J.t option =
  let rec headers len =
    match input_line ic with
    | exception End_of_file -> None
    | line ->
      let line = trim_cr line in
      if line = "" then len
      else headers (match content_length_of line with Some n -> Some n | None -> len)
  in
  match headers None with
  | None -> None
  | Some n ->
    (match really_input_string ic n with
     | exception End_of_file -> None
     | body ->
       (match J.from_string body with
        | json -> Some json
        | exception _ -> None))

let write_message oc (json : J.t) =
  let s = J.to_string json in
  output_string oc (Printf.sprintf "Content-Length: %d\r\n\r\n" (String.length s));
  output_string oc s;
  flush oc

(* ── Messages out ────────────────────────────────────────────────────────── *)

let response id result : J.t =
  `Assoc [("jsonrpc", `String "2.0"); ("id", id); ("result", result)]

let error_response id code message : J.t =
  `Assoc [("jsonrpc", `String "2.0"); ("id", id);
          ("error", `Assoc [("code", `Int code); ("message", `String message)])]

let notification method_ params : J.t =
  `Assoc [("jsonrpc", `String "2.0"); ("method", `String method_);
          ("params", params)]

(* ── Diagnostics ─────────────────────────────────────────────────────────── *)

(* wand positions are 1-based extents; LSP ranges are 0-based. A diagnostic
   without a position lands at the top of the file. *)
let range_of_loc (loc : Token.loc option) : J.t =
  let pos line col =
    `Assoc [("line", `Int (max 0 (line - 1)));
            ("character", `Int (max 0 (col - 1)))]
  in
  match loc with
  | None -> `Assoc [("start", pos 1 1); ("end", pos 1 1)]
  | Some l ->
    let end_ =
      if l.Token.end_offset > l.Token.offset
      then pos l.Token.end_line l.Token.end_col
      else pos l.Token.line l.Token.col
    in
    `Assoc [("start", pos l.Token.line l.Token.col); ("end", end_)]

let json_of_diag (d : Diag.t) : J.t =
  `Assoc [
    ("range", range_of_loc d.Diag.loc);
    ("severity", `Int (match d.Diag.severity with Diag.Error -> 1 | Diag.Warning -> 2));
    ("code", `String d.Diag.code);
    ("source", `String "wand");
    ("message", `String d.Diag.message);
  ]

(* file:// URIs carry a percent-encoded filesystem path; anything else
   (untitled: buffers) keeps its tail as a relative name, which
   `typecheck_source` resolves against the working directory. *)
let percent_decode s =
  let buf = Buffer.create (String.length s) in
  let n = String.length s in
  let hex c =
    match c with
    | '0'..'9' -> Some (Char.code c - Char.code '0')
    | 'a'..'f' -> Some (Char.code c - Char.code 'a' + 10)
    | 'A'..'F' -> Some (Char.code c - Char.code 'A' + 10)
    | _ -> None
  in
  let i = ref 0 in
  while !i < n do
    (match s.[!i] with
     | '%' when !i + 2 < n ->
       (match hex s.[!i + 1], hex s.[!i + 2] with
        | Some h, Some l -> Buffer.add_char buf (Char.chr ((h lsl 4) lor l)); i := !i + 2
        | _ -> Buffer.add_char buf '%')
     | c -> Buffer.add_char buf c);
    incr i
  done;
  Buffer.contents buf

let path_of_uri uri =
  let file_prefix = "file://" in
  if String.length uri > String.length file_prefix
     && String.sub uri 0 (String.length file_prefix) = file_prefix
  then
    percent_decode
      (String.sub uri (String.length file_prefix)
         (String.length uri - String.length file_prefix))
  else
    match String.index_opt uri ':' with
    | Some i -> String.sub uri (i + 1) (String.length uri - i - 1)
    | None -> uri

(* What the Problems pane shows for one buffer: the check's single error,
   or its findings. Holes wait for locations (LSP.md §5.1); a diagnostic
   that cannot point anywhere is noise, not information. *)
let diagnostics_for uri text : Diag.t list =
  match Runner.typecheck_source ~path:(path_of_uri uri) text with
  | Error d -> [d]
  | Ok sc -> List.map (Lint.to_diag ~strict:false) sc.Runner.sc_findings

let publish uri diags =
  notification "textDocument/publishDiagnostics"
    (`Assoc [("uri", `String uri);
             ("diagnostics", `List (List.map json_of_diag diags))])

(* ── The protocol ────────────────────────────────────────────────────────── *)

type state = {
  docs : (string * string) list;  (* uri -> current text *)
  shutdown_seen : bool;
  quit : int option;              (* Some code once `exit` arrives *)
}

let initial = { docs = []; shutdown_seen = false; quit = None }

let capabilities : J.t =
  `Assoc [
    ("capabilities", `Assoc [
       (* Full-text sync: the whole buffer per change, which is what the
          checker consumes anyway (LSP.md §1: no incrementality). *)
       ("textDocumentSync", `Assoc [("openClose", `Bool true);
                                    ("change", `Int 1)]);
     ]);
    ("serverInfo", `Assoc [("name", `String "wand");
                           ("version", `String Version.value)]);
  ]

let handle (st : state) (msg : J.t) : state * J.t list =
  let id = mem "id" msg in
  let params = mem "params" msg in
  let check_and_publish st uri text =
    ({ st with docs = (uri, text) :: List.remove_assoc uri st.docs },
     [publish uri (diagnostics_for uri text)])
  in
  match str (mem "method" msg) with
  (* After shutdown, only exit does anything; a request in between is the
     client's error and is told so. *)
  | Some m when st.shutdown_seen && m <> "exit" ->
    if id = `Null then (st, [])
    else (st, [error_response id (-32600) "shutdown has been requested"])
  | Some "initialize" -> (st, [response id capabilities])
  | Some "initialized" -> (st, [])
  | Some "shutdown" -> ({ st with shutdown_seen = true }, [response id `Null])
  | Some "exit" -> ({ st with quit = Some (if st.shutdown_seen then 0 else 1) }, [])
  | Some "textDocument/didOpen" ->
    let doc = mem "textDocument" params in
    (match str (mem "uri" doc), str (mem "text" doc) with
     | Some uri, Some text -> check_and_publish st uri text
     | _ -> (st, []))
  | Some "textDocument/didChange" ->
    let uri = str (mem "uri" (mem "textDocument" params)) in
    (* Full sync: each change carries the entire text; the last one wins. *)
    let text =
      match mem "contentChanges" params with
      | `List (_ :: _ as changes) -> str (mem "text" (List.nth changes (List.length changes - 1)))
      | _ -> None
    in
    (match uri, text with
     | Some uri, Some text -> check_and_publish st uri text
     | _ -> (st, []))
  | Some "textDocument/didClose" ->
    (match str (mem "uri" (mem "textDocument" params)) with
     | Some uri ->
       ({ st with docs = List.remove_assoc uri st.docs }, [publish uri []])
     | None -> (st, []))
  | Some _ ->
    (* Unknown notifications are ignored by contract; unknown requests are
       answered, or the client waits forever. *)
    if id = `Null then (st, [])
    else (st, [error_response id (-32601) "method not found"])
  | None -> (st, [])

(* ── The stdio instantiation ─────────────────────────────────────────────── *)

let serve ic oc : int =
  set_binary_mode_in ic true;
  set_binary_mode_out oc true;
  let rec loop st =
    match st.quit with
    | Some code -> code
    | None ->
      match read_message ic with
      | None ->
        (* The client went away without `exit`. *)
        if st.shutdown_seen then 0 else 1
      | Some msg ->
        let (st, outgoing) = handle st msg in
        List.iter (write_message oc) outgoing;
        loop st
  in
  loop initial
